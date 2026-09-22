import AppKit
import CoreServices
import Darwin

/// One recursive, event-driven stream for a window's workspace and any open
/// files outside it. No directory walk, extension filter or idle polling.
@MainActor
final class FileChangeMonitor {
    private var stream:FSEventStreamRef?
    private var openFiles:[String:DispatchSourceFileSystemObject]=[:]
    private let fileQueue=DispatchQueue(label:"app.orkhon.open-file-events",qos:.utility)
    private var context:EventContext?
    private var needsRestart=false
    private(set) var roots:[String]=[]
    var onChange:(()->Void)?
    private final class EventContext {
        weak var owner:FileChangeMonitor?
        init(_ owner:FileChangeMonitor) {self.owner=owner}
    }
    func update(_ urls:[URL],workspace:URL?=nil,rearm:Bool=false) {
        // Direct vnode notifications preserve fast open-buffer/conflict detection
        // even when the system-wide FSEvents daemon is batching directory events.
        updateOpenFiles(urls,rearm:rearm)
        let paths=Self.compactRoots((workspace.map{[$0]} ?? [])+urls.map{$0.deletingLastPathComponent()})
        guard paths != roots || needsRestart else{return}
        needsRestart=false
        stopStream();roots=paths;guard !paths.isEmpty else{return}
        let token=EventContext(self);context=token
        var info=FSEventStreamContext(version:0,info:Unmanaged.passUnretained(token).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        let callback:FSEventStreamCallback = {_,info,count,eventPaths,eventFlags,_ in
            guard let info else{return}
            let token=Unmanaged<EventContext>.fromOpaque(info).takeUnretainedValue()
            let paths=unsafeBitCast(eventPaths,to:NSArray.self) as? [String] ?? []
            // Preview/SSH/recovery caches must never cause a self-refresh loop
            // when an automatic workspace happens to include the temp directory.
            guard paths.contains(where:{!FileChangeMonitor.isPrivateCache($0)}) else{return}
            MainActor.assumeIsolated {
                if (0..<count).contains(where:{eventFlags[$0] & UInt32(kFSEventStreamEventFlagRootChanged) != 0}) {token.owner?.needsRestart=true}
                token.owner?.onChange?()
            }
        }
        let flags=kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
        guard let next=FSEventStreamCreate(nil,callback,&info,paths as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.1,FSEventStreamCreateFlags(flags)) else{return}
        stream=next;FSEventStreamSetDispatchQueue(next,.main)
        if !FSEventStreamStart(next) {stopStream()}
    }
    nonisolated static func compactRoots(_ urls:[URL])->[String] {
        let sorted=Set(urls.map{$0.standardizedFileURL.resolvingSymlinksInPath().path}).sorted{$0.count<$1.count}
        return sorted.reduce(into:[String]()) {roots,path in
            if !roots.contains(where:{path==$0 || path.hasPrefix($0=="/" ? "/":$0+"/")}) {roots.append(path)}
        }.sorted()
    }
    private nonisolated static let temporaryPrefix=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path+"/orkhon-preview-"
    private nonisolated static let recoveryPrefix=NSHomeDirectory()+"/Library/Application Support/Orkhon Editor/"
    nonisolated static func isPrivateCache(_ path:String)->Bool {
        let normalized=path.hasPrefix("/private/") ? String(path.dropFirst(8)):path
        if normalized.hasPrefix("/tmp/orkhon-ssh-") || normalized.hasPrefix("/tmp/orkhon-preview-") {return true}
        return path.hasPrefix(temporaryPrefix) || path.hasPrefix(recoveryPrefix)
    }
    private func updateOpenFiles(_ urls:[URL],rearm:Bool) {
        let paths=Set(urls.flatMap{[$0.path,$0.deletingLastPathComponent().path]})
        for path in Array(openFiles.keys) where rearm || !paths.contains(path) {openFiles.removeValue(forKey:path)?.cancel()}
        for path in paths where openFiles[path]==nil {
            let fd=open(path,O_EVTONLY|O_CLOEXEC);guard fd>=0 else{continue}
            let source=DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete,.attrib,.extend],queue:fileQueue)
            source.setEventHandler { [weak self] in DispatchQueue.main.async {self?.onChange?()} }
            source.setCancelHandler {close(fd)};openFiles[path]=source;source.resume()
        }
    }
    func stop() {openFiles.values.forEach{$0.cancel()};openFiles=[:];stopStream()}
    private func stopStream() {
        if let stream {FSEventStreamStop(stream);FSEventStreamInvalidate(stream);FSEventStreamRelease(stream)}
        stream=nil;context=nil;roots=[]
    }
    deinit {openFiles.values.forEach{$0.cancel()};if let stream {FSEventStreamStop(stream);FSEventStreamInvalidate(stream);FSEventStreamRelease(stream)}}
}

/// A long-lived SSH channel carries only short event messages. Files still use
/// the existing bounded transport and optimistic save/conflict machinery.
@MainActor
final class RemoteChangeMonitor {
    private var process:Process?
    private var input:Pipe?,output:Pipe?
    private var revision=UUID()
    private var roots:[String]=[]
    private weak var connection:RemoteWorkspace?
    private var pending=Data()
    private var retry:DispatchWorkItem?
    private var retryDelay:Double=5
    private(set) var eventDriven=false
    var onChange:(()->Void)?
    var onAvailability:((Bool)->Void)?
    func update(connection:RemoteWorkspace?,paths:[String]) {
        let roots=Set(paths.map{($0 as NSString).standardizingPath}).sorted{$0.count<$1.count}.reduce(into:[String]()) {result,path in
            if !result.contains(where:{path==$0 || path.hasPrefix($0=="/" ? "/":$0+"/")}) {result.append(path)}
        }.sorted()
        guard self.connection !== connection || self.roots != roots else{return}
        stop();self.connection=connection;self.roots=roots;retryDelay=5
        guard connection != nil,!roots.isEmpty else{return}
        start()
    }
    private func start() {
        guard let connection,!roots.isEmpty else{return}
        let revision=UUID();self.revision=revision;pending=Data()
        do {
            guard let url=Bundle.main.url(forResource:"workspace_watch",withExtension:"py") else {throw RemoteFailure(message:"Workspace watcher is missing.")}
            let source=try String(contentsOf:url,encoding:.utf8)
            let script="exec python3 -u -c "+RemoteWorkspace.quote(source)+" "+roots.map(RemoteWorkspace.quote).joined(separator:" ")
            let input=Pipe(),output=Pipe();self.input=input;self.output=output
            let process=try connection.startEventProcess(script,input:input,output:output) { [weak self] in
                DispatchQueue.main.async {self?.ended(revision)}
            }
            self.process=process
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data=handle.availableData
                DispatchQueue.main.async {
                    guard let self,self.revision==revision else{return}
                    if data.isEmpty {self.ended(revision);return}
                    self.pending.append(data)
                    guard self.pending.count<=8192 else{self.ended(revision);return}
                    while let newline=self.pending.firstIndex(of:10) {
                        let line=String(decoding:self.pending[..<newline],as:UTF8.self);self.pending.removeSubrange(...newline)
                        if line=="ready" {self.retryDelay=5;self.eventDriven=true;self.onAvailability?(true);self.onChange?()}
                        else if line=="change" {self.onChange?()}
                    }
                }
            }
            // If startup never becomes ready, reconcile with bounded polling.
            let timeout=DispatchWorkItem { [weak self] in
                guard let self,self.revision==revision,!self.eventDriven else{return};self.onAvailability?(false)
            }
            retry=timeout;DispatchQueue.main.asyncAfter(deadline:.now()+5,execute:timeout)
        } catch {ended(revision)}
    }
    private func ended(_ generation:UUID) {
        guard revision==generation else{return}
        let connection=connection,roots=roots,delay=retryDelay
        stop();self.connection=connection;self.roots=roots;retryDelay=min(60,delay*2)
        guard connection != nil,!roots.isEmpty else{return}
        onAvailability?(false)
        let item=DispatchWorkItem { [weak self] in self?.start() };retry=item
        DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:item)
    }
    func stop() {
        revision=UUID();retry?.cancel();retry=nil
        output?.fileHandleForReading.readabilityHandler=nil
        // EOF on stdin stops the server helper, including idle SSH channels.
        try? input?.fileHandleForWriting.close();input=nil
        if let process,process.isRunning {process.terminate()}
        process=nil;output=nil;eventDriven=false;roots=[];connection=nil
    }
    deinit {
        retry?.cancel();output?.fileHandleForReading.readabilityHandler=nil
        try? input?.fileHandleForWriting.close()
        if let process,process.isRunning {process.terminate()}
    }
}
