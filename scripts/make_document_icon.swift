import AppKit
let output=CommandLine.arguments[1],logo=NSImage(contentsOfFile:CommandLine.arguments[2])!
try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
for points in [16,32,128,256,512] {for scale in [1,2] {
 let size=points*scale
 let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
 let transform=NSAffineTransform();transform.scale(by:CGFloat(size)/1024);transform.concat()
 let page=NSBezierPath();page.move(to:NSPoint(x:210,y:70));page.line(to:NSPoint(x:814,y:70));page.line(to:NSPoint(x:814,y:744));page.line(to:NSPoint(x:618,y:954));page.line(to:NSPoint(x:210,y:954));page.close()
 NSColor(srgbRed:0.94,green:0.96,blue:0.98,alpha:1).setFill();page.fill();NSColor(srgbRed:0.60,green:0.66,blue:0.71,alpha:1).setStroke();page.lineWidth=14;page.stroke()
 let fold=NSBezierPath();fold.move(to:NSPoint(x:618,y:954));fold.line(to:NSPoint(x:618,y:744));fold.line(to:NSPoint(x:814,y:744));fold.close();NSColor(srgbRed:0.77,green:0.83,blue:0.86,alpha:1).setFill();fold.fill()
 logo.draw(in:NSRect(x:243,y:202,width:538,height:538),from:.zero,operation:.sourceOver,fraction:1)
 NSGraphicsContext.restoreGraphicsState();try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output+"/icon_\(points)x\(points)\(scale==2 ? "@2x":"").png"))
}}
