import Foundation

final class Lines:@unchecked Sendable {
    private let lock=NSLock()
    private var data=Data(),values:[String]=[]
    func append(_ bytes:Data) {lock.lock();defer{lock.unlock()};data.append(bytes);while let i=data.firstIndex(of:10) {values.append(String(decoding:data[..<i],as:UTF8.self));data.removeSubrange(...i)}}
    func take()->[String] {lock.lock();defer{lock.unlock()};let result=values;values=[];return result}
}

@main struct RemoteEventStress {
    static func require(_ value:Bool,_ message:String)throws {if !value {throw RemoteFailure(message:message)}}
    static func wait(_ predicate:()->Bool,timeout:Double=10)throws {
        let end=Date().addingTimeInterval(timeout)
        while !predicate() {if Date()>end {throw RemoteFailure(message:"Test timed out")};Thread.sleep(forTimeInterval:0.02)}
    }
    static func main() {
        do {try run()} catch {fputs("FAIL: \(error.localizedDescription)\n",stderr);exit(1)}
    }
    static func run()throws {
        let args=CommandLine.arguments
        guard args.count==4,let port=Int(args[1]) else{throw RemoteFailure(message:"Usage: stress-remote-events PORT KEY HELPER")}
        let connection=try RemoteWorkspace(host:"root@127.0.0.1",directory:"/workspace",port:port)
        let master=Process();master.executableURL=URL(fileURLWithPath:"/usr/bin/ssh")
        master.arguments=["-M","-N","-F","/dev/null","-i",args[2],"-p",String(port),"-o","BatchMode=yes","-o","IdentitiesOnly=yes","-o","UserKnownHostsFile="+connection.cacheURL.appendingPathComponent("known_hosts").path,"-o","StrictHostKeyChecking=accept-new","-o","ControlPath="+connection.controlPath,"--",connection.host]
        master.standardInput=FileHandle.nullDevice;master.standardOutput=FileHandle.nullDevice;master.standardError=FileHandle.nullDevice
        try master.run();defer{connection.disconnect();if master.isRunning {master.terminate()}}
        try wait{connection.ready || !master.isRunning};try require(connection.ready,"Local SSH handshake failed")
        func python(_ source:String)throws->Data {try connection.run("python3 -c "+RemoteWorkspace.quote(source))}
        _ = try python("""
        from pathlib import Path
        root=Path('/workspace');root.mkdir(exist_ok=True)
        for i in range(100):
          folder=root/str(i);folder.mkdir(exist_ok=True)
          for j in range(50): (folder/(str(j)+'.any')).write_text('initial')
        """)
        let helper=try String(contentsOfFile:args[3],encoding:.utf8)
        let script="exec python3 -u -c "+RemoteWorkspace.quote(helper)+" /workspace"
        var batches:[Int]=[]
        for cycle in 0..<10 {
            let input=Pipe(),output=Pipe(),lines=Lines()
            output.fileHandleForReading.readabilityHandler={handle in let data=handle.availableData;if !data.isEmpty {lines.append(data)}}
            let process=try connection.startEventProcess(script,input:input,output:output,onExit:{})
            var ready=false
            try wait {ready = ready || lines.take().contains("ready");return ready || !process.isRunning}
            try require(ready,"Remote helper did not become ready")
            if cycle<3 {
                _ = lines.take()
                _ = try python("""
                from pathlib import Path
                import os
                root=Path('/workspace')
                for i in range(100):
                  folder=root/str(i)
                  for j in range(20):
                    tmp=folder/'temporary';tmp.write_text('wave \\(cycle)');os.replace(tmp,folder/(str(j)+'.any'))
                  new=folder/'new';new.mkdir();(new/'extensionless').write_text('extra');new.rename(folder/'moved-\\(cycle)')
                """.replacingOccurrences(of:"\\(cycle)",with:String(cycle)))
                var count=0
                try wait {count+=lines.take().filter{$0=="change"}.count;return count>0}
                batches.append(count)
                let data=try connection.read("/workspace/0/0.any")
                try require(String(decoding:data,as:UTF8.self)=="wave \(cycle)","Latest bytes did not survive burst")
                let hashes=try connection.checksums(["/workspace/0/0.any"])
                try require(hashes["/workspace/0/0.any"]==RemoteWorkspace.checksum(data),"Event reconciliation digest mismatch")
            }
            if cycle==0 {
                let metrics=try python("""
                import os,time,json
                def helpers():
                  result=[]
                  for value in os.listdir('/proc'):
                    if not value.isdigit() or int(value)==os.getpid(): continue
                    try:
                      args=open('/proc/'+value+'/cmdline','rb').read().split(b'\\0')
                      if args[0].endswith(b'python3') and len(args)>3 and b'Orkhon SSH event helper' in args[3]: result.append(value)
                    except OSError: pass
                  return result
                pid=helpers()[0]
                def ticks():
                  fields=open('/proc/'+pid+'/stat').read().split();return int(fields[13])+int(fields[14])
                before=ticks();time.sleep(3);after=ticks()
                rss=int(open('/proc/'+pid+'/statm').read().split()[1])*os.sysconf('SC_PAGE_SIZE')
                print(json.dumps({'idleCPUSeconds':(after-before)/os.sysconf('SC_CLK_TCK'),'idleDurationSeconds':3,'residentBytes':rss}))
                """)
                print(String(decoding:metrics,as:UTF8.self))
            }
            if cycle==9 {process.terminate()} else {try input.fileHandleForWriting.close()}
            try wait{!process.isRunning};process.waitUntilExit()
            output.fileHandleForReading.readabilityHandler=nil
            if cycle != 9 {try require(process.terminationStatus==0,"Event channel did not exit cleanly")}
            print("PASS: real SSH event cycle \(cycle+1)")
        }
        let remaining=try python("""
        import os
        found=[]
        for value in os.listdir('/proc'):
          if not value.isdigit() or int(value)==os.getpid(): continue
          try:
            args=open('/proc/'+value+'/cmdline','rb').read().split(b'\\0')
            if args[0].endswith(b'python3') and len(args)>3 and b'Orkhon SSH event helper' in args[3]: found.append(value)
          except OSError: pass
        print(len(found))
        """)
        try require(String(decoding:remaining,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)=="0","Orphaned remote watcher")
        print("PASS: 5,000 files, 6,600 changes, ten SSH event channels, abrupt disconnect, zero orphan helpers; notifications \(batches)")
    }
}
