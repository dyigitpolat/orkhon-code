import AppKit
let output=CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
for points in [16,32,128,256,512] {
 for scale in [1,2] {
 let size=points*scale
 let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
 let s=CGFloat(size)/1024
 let transform=NSAffineTransform();transform.scale(by:s);transform.concat()
 let base=NSBezierPath(roundedRect:NSRect(x:70,y:70,width:884,height:884),xRadius:204,yRadius:204)
 NSGradient(starting:NSColor(srgbRed:0.15,green:0.20,blue:0.23,alpha:1),ending:NSColor(srgbRed:0.06,green:0.09,blue:0.13,alpha:1))!.draw(in:base,angle:-75)
 let glyph=NSBezierPath();glyph.move(to:NSPoint(x:346,y:320));glyph.line(to:NSPoint(x:346,y:694));glyph.line(to:NSPoint(x:514,y:790));glyph.line(to:NSPoint(x:682,y:694));glyph.line(to:NSPoint(x:682,y:320));glyph.line(to:NSPoint(x:514,y:224));glyph.close()
 glyph.lineWidth=45;glyph.lineJoinStyle = .round;NSColor(srgbRed:0.56,green:0.86,blue:0.77,alpha:1).setStroke();glyph.stroke()
 let spine=NSBezierPath();spine.move(to:NSPoint(x:514,y:750));spine.line(to:NSPoint(x:514,y:264));spine.move(to:NSPoint(x:358,y:578));spine.line(to:NSPoint(x:514,y:480));spine.line(to:NSPoint(x:670,y:578));spine.lineWidth=32;spine.lineCapStyle = .round;spine.stroke()
 NSGraphicsContext.restoreGraphicsState()
 let data=rep.representation(using:.png,properties:[:])!
 try data.write(to:URL(fileURLWithPath:output+"/icon_\(points)x\(points)\(scale == 2 ? "@2x":"").png"))
 }
}
