import Foundation
import CryptoKit
import Darwin

struct RemoteEntry:Sendable {let path:String;let directory:Bool;let symbolicLink:Bool;var name:String {(path as NSString).lastPathComponent}}
struct RemoteFailure:LocalizedError {
    let message:String,exitStatus:Int32?
    init(message:String,exitStatus:Int32?=nil) {self.message=message;self.exitStatus=exitStatus}
    var errorDescription:String? {message}
}

/// Uses the macOS OpenSSH client: its config, agent, authentication and host-key checks.
/// All file operations run away from the UI. Commands quote every remote pathname.
final class RemoteWorkspace:@unchecked Sendable {
    let host:String
    let port:Int?
    private var master:Process?
    let controlPath:String
    let cacheURL:URL
    // The composition root changes this only on the main actor, after canonicalization.
    var directory:String
    private let localTest:Bool
    private let stateLock=NSLock()
    private var disconnectRequested=false
    private var requests:[Int32:Process]=[:]
    init(host:String,directory:String,localTest:Bool=false,port:Int?=nil) throws {
        guard Self.validHost(host) else {throw RemoteFailure(message:"Enter an SSH-config alias or user@hostname, without options or spaces.")}
        guard port == nil || (1...65535).contains(port!) else {throw RemoteFailure(message:"Port must be between 1 and 65535.")}
        self.port=port
        self.host=host;self.directory=directory;self.localTest=localTest
        cacheURL=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("orkhon-ssh-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:cacheURL,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        controlPath=cacheURL.appendingPathComponent("connection").path
    }
    static func validHost(_ host:String)->Bool { !host.isEmpty && !host.hasPrefix("-") && host.range(of:"^[A-Za-z0-9_.@:\\[\\]-]+$",options:.regularExpression) != nil }
    static func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    var terminalArguments:[String] {
        let cd=directory.isEmpty ? "cd":"cd -- "+Self.quote(directory)
        return ["-tt","-o","BatchMode=yes","-o","ControlMaster=no","-o","ControlPath=\(controlPath)","-o","StrictHostKeyChecking=yes"]+portArguments+["--",host,cd+" && exec \"${SHELL:-/bin/sh}\" -l"]
    }
    var portArguments:[String] {port.map{["-p",String($0)]} ?? []}
    var ready:Bool {localTest || FileManager.default.fileExists(atPath:controlPath)}
    /// OpenSSH owns key/agent selection, password prompts and known-host verification.
    /// The bundled askpass helper displays native secure input; passwords are never stored.
    func connect(askpass:URL)throws {
        if localTest {return}
        let log=cacheURL.appendingPathComponent("connection.log")
        FileManager.default.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600])
        let stderr=try FileHandle(forWritingTo:log);defer{try? stderr.close()}
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/ssh")
        process.arguments=["-M","-N","-o","ControlMaster=yes","-o","ControlPersist=no","-o","ControlPath=\(controlPath)","-o","StrictHostKeyChecking=ask","-o","ConnectTimeout=20","-o","ServerAliveInterval=15","-o","ServerAliveCountMax=3"]+portArguments+["--",host]
        var environment=ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"]=askpass.path;environment["SSH_ASKPASS_REQUIRE"]="force"
        process.environment=environment;process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=stderr
        stateLock.lock()
        if disconnectRequested {stateLock.unlock();throw CancellationError()}
        do {try process.run();master=process;stateLock.unlock()} catch {stateLock.unlock();throw error}
        let deadline=Date().addingTimeInterval(300)
        while process.isRunning && !ready && Date()<deadline {
            stateLock.lock();let cancelled=disconnectRequested;stateLock.unlock()
            if cancelled {Self.stop(process);throw CancellationError()}
            Thread.sleep(forTimeInterval:0.05)
        }
        guard ready,process.isRunning else {
            Self.stop(process)
            let message=(try? String(contentsOf:log,encoding:.utf8)) ?? ""
            throw RemoteFailure(message:message.isEmpty ? "Connection timed out or authentication was cancelled.":String(message.suffix(8000)))
        }
    }
    func canonicalDirectory(_ path:String)throws->String {
        let command=(path.isEmpty ? "cd":"cd -- "+Self.quote(path))+" && pwd -P"
        return try String(decoding:run(command),as:UTF8.self).trimmingCharacters(in:.newlines)
    }
    static func checksum(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    func checksums(_ paths:[String])throws->[String:String] {
        guard !paths.isEmpty else{return [:]}
        let script="""
        set -eu
        for path in \(paths.map(Self.quote).joined(separator:" ")); do
            if [ ! -f "$path" ] || [ -L "$path" ]; then printf 'missing\\000'; continue; fi
            size=$(wc -c < "$path")
            if [ "$size" -gt 33554432 ]; then printf 'oversize\\000'; continue; fi
            if command -v sha256sum >/dev/null 2>&1; then hash=$(sha256sum < "$path")
            elif command -v shasum >/dev/null 2>&1; then hash=$(shasum -a 256 < "$path")
            elif command -v sha256 >/dev/null 2>&1; then hash=$(sha256 -q < "$path")
            else echo 'The server needs sha256sum, shasum, or sha256 for change monitoring.' >&2; exit 69; fi
            printf '%s\\000' "${hash%% *}"
        done
        """
        let values=try run(script,limit:max(4096,paths.count*80)).split(separator:0).map{String(decoding:$0,as:UTF8.self)}
        guard values.count==paths.count else{throw RemoteFailure(message:"The server returned an invalid file-change response.")}
        return Dictionary(zip(paths,values),uniquingKeysWith:{$1})
    }
    func list(_ path:String)throws->[RemoteEntry] {
        let script="""
        set -eu
        cd -- \(Self.quote(path))
        for entry in ./* ./.[!.]* ./..?*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            kind=f
            if [ -L "$entry" ]; then kind=l; elif [ -d "$entry" ]; then kind=d; fi
            printf '%s\\000%s\\000' "$kind" "${entry#./}"
        done
        """
        let fields=try run(script,limit:8*1024*1024).split(separator:0,omittingEmptySubsequences:false)
        var entries:[RemoteEntry]=[]
        for i in stride(from:0,to:max(0,fields.count-1),by:2) {
            guard i+1<fields.count,let name=String(data:Data(fields[i+1]),encoding:.utf8),!name.isEmpty else {continue}
            let kind=String(decoding:fields[i],as:UTF8.self)
            entries.append(RemoteEntry(path:(path as NSString).appendingPathComponent(name),directory:kind=="d",symbolicLink:kind=="l"))
        }
        guard entries.count<=20000 else {throw RemoteFailure(message:"This folder has more than 20,000 entries. Open a more specific remote folder.")}
        return entries.sorted{$0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
    func read(_ path:String,limit:Int=32*1024*1024)throws->Data {
        let q=Self.quote(path)
        return try run("[ -f \(q) ] && [ ! -L \(q) ] || { echo 'Open a regular file; symbolic links are not edited remotely.' >&2; exit 65; }; cat < \(q)",limit:limit)
    }
    func write(_ path:String,data:Data,expected:Data)throws {
        let hash=SHA256.hash(data:expected).map{String(format:"%02x",$0)}.joined()
        let script="""
        set -eu
        path=\(Self.quote(path))
        [ -f "$path" ] && [ ! -L "$path" ] || { echo 'The remote file was removed or replaced.' >&2; exit 65; }
        digest() {
            if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$path" | cut -d ' ' -f 1
            elif command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$path" | cut -d ' ' -f 1
            elif command -v sha256 >/dev/null 2>&1; then sha256 -q < "$path"
            else echo 'The server needs sha256sum, shasum, or sha256 for safe saves.' >&2; return 69; fi
        }
        [ "$(digest)" = \(Self.quote(hash)) ] || { echo 'Conflict: the file changed on the server. Reopen it or save a local copy.' >&2; exit 73; }
        temporary=$(mktemp "${path%/*}/.orkhon-save.XXXXXXXX")
        trap 'rm -f "$temporary"' EXIT HUP INT TERM
        cp -p "$path" "$temporary"
        cat > "$temporary"
        [ "$(digest)" = \(Self.quote(hash)) ] || { echo 'Conflict: the server file changed during upload.' >&2; exit 73; }
        mv -f "$temporary" "$path"
        trap - EXIT HUP INT TERM
        """
        _ = try run(script,input:data)
    }
    func create(_ path:String,directory:Bool)throws {
        _ = try run(directory ? "mkdir -- "+Self.quote(path) : "(set -C; : > "+Self.quote(path)+")")
    }
    func disconnect() {
        stateLock.lock();let already=disconnectRequested;disconnectRequested=true;let process=master;master=nil;let pending=Array(requests.values);stateLock.unlock()
        guard !already else{return}
        let cache=cacheURL,path=controlPath,destination=host,shouldStop = !localTest && ready
        if !shouldStop {DispatchQueue.global(qos:.utility).async {pending.forEach(Self.stop);if let process {Self.stop(process)};try? FileManager.default.removeItem(at:cache)};return}
        DispatchQueue.global(qos:.utility).async {
            pending.forEach(Self.stop)
            let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/ssh");p.arguments=["-S",path,"-O","exit","--",destination];p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
            if (try? p.run()) != nil {
                let deadline=Date().addingTimeInterval(3)
                while p.isRunning && Date()<deadline {Thread.sleep(forTimeInterval:0.02)}
                if p.isRunning {Self.stop(p)}
            }
            if let process {Self.stop(process)}
            try? FileManager.default.removeItem(at:cache)
        }
    }
    deinit {disconnect()}
    private static func stop(_ process:Process) {
        guard process.isRunning else{return};process.terminate()
        let deadline=Date().addingTimeInterval(0.5)
        while process.isRunning && Date()<deadline {Thread.sleep(forTimeInterval:0.01)}
        if process.isRunning {kill(process.processIdentifier,SIGKILL)}
        process.waitUntilExit()
    }
    /// Multiplexed event channel. The caller owns stdin and closes it to cancel.
    func startEventProcess(_ script:String,input:Pipe,output:Pipe,onExit:@escaping @Sendable ()->Void)throws->Process {
        let p=Process();p.executableURL=URL(fileURLWithPath:localTest ? "/bin/sh":"/usr/bin/ssh")
        p.arguments=localTest ? ["-c",script] : ["-T","-o","BatchMode=yes","-o","ConnectTimeout=10","-o","ServerAliveInterval=10","-o","ServerAliveCountMax=2","-o","StrictHostKeyChecking=yes","-o","ControlPath=\(controlPath)"]+portArguments+["--",host,"/bin/sh -c "+Self.quote(script)]
        p.standardInput=input;p.standardOutput=output;p.standardError=FileHandle.nullDevice
        p.terminationHandler = { [weak self] process in
            if let self {self.stateLock.lock();self.requests.removeValue(forKey:process.processIdentifier);self.stateLock.unlock()}
            onExit()
        }
        stateLock.lock();defer{stateLock.unlock()}
        if disconnectRequested {throw CancellationError()}
        try p.run();requests[p.processIdentifier]=p;return p
    }
    func run(_ script:String,input:Data?=nil,limit:Int=1024*1024)throws->Data {
        let request=cacheURL.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:request,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:request)}
        let output=request.appendingPathComponent("output"),error=request.appendingPathComponent("error"),upload=request.appendingPathComponent("input")
        for url in [output,error,upload] {FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600])}
        if let input {try input.write(to:upload)}
        let stdout=try FileHandle(forWritingTo:output),stderr=try FileHandle(forWritingTo:error),stdin=try FileHandle(forReadingFrom:upload)
        defer{try? stdout.close();try? stderr.close();try? stdin.close()}
        let p=Process();p.executableURL=URL(fileURLWithPath:localTest ? "/bin/sh":"/usr/bin/ssh")
        p.arguments=localTest ? ["-c",script] : ["-o","BatchMode=yes","-o","ConnectTimeout=10","-o","ServerAliveInterval=10","-o","ServerAliveCountMax=2","-o","StrictHostKeyChecking=yes","-o","ControlPath=\(controlPath)"]+portArguments+["--",host,"/bin/sh -c "+Self.quote(script)]
        p.standardInput=stdin;p.standardOutput=stdout;p.standardError=stderr
        stateLock.lock()
        if disconnectRequested {stateLock.unlock();throw CancellationError()}
        do {try p.run();requests[p.processIdentifier]=p;stateLock.unlock()} catch {stateLock.unlock();throw error}
        defer{stateLock.lock();requests.removeValue(forKey:p.processIdentifier);stateLock.unlock()}
        let deadline=Date().addingTimeInterval(60)
        while p.isRunning {
            let size=(try? FileManager.default.attributesOfItem(atPath:output.path)[.size] as? NSNumber)?.intValue ?? 0
            let errorSize=(try? FileManager.default.attributesOfItem(atPath:error.path)[.size] as? NSNumber)?.intValue ?? 0
            if size>limit || errorSize>1024*1024 || Date()>deadline {Self.stop(p);throw RemoteFailure(message:size>limit || errorSize>1024*1024 ? "The remote response exceeds the safe size limit (32 MB for files).":"The SSH operation timed out. Reconnect and try again.")}
            Thread.sleep(forTimeInterval:0.02)
        }
        p.waitUntilExit()
        guard p.terminationStatus==0 else {
            let handle=try? FileHandle(forReadingFrom:error);defer{try? handle?.close()}
            let message=String(decoding:(try? handle?.read(upToCount:1024*1024)) ?? Data(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            throw RemoteFailure(message:message.isEmpty ? "SSH operation failed (\(p.terminationStatus)).":message,exitStatus:p.terminationStatus)
        }
        let finalSize=(try FileManager.default.attributesOfItem(atPath:output.path)[.size] as? NSNumber)?.intValue ?? 0
        guard finalSize<=limit else {throw RemoteFailure(message:"Remote response is too large.")}
        let data=try Data(contentsOf:output);guard data.count<=limit else {throw RemoteFailure(message:"Remote response is too large.")};return data
    }
}
