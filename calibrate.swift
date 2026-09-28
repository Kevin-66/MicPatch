// Builds a clean (icon-free) image of the menu bar background from a full-screen screenshot.
import Foundation
import ImageIO
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let shot = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("usage: calibrate <screenshot> <out.png> [screenWidthPt]"); exit(1) }
let screenW = args.count > 3 ? Double(args[3])! : 1710.0
let k = 2.0                                   // output pixels per point
let bandPt = 35.0
let ss = Double(shot.width) / screenW         // screenshot px per pt
let W = Int(screenW * k), H = Int(bandPt * k)
var px = [Float](repeating: 0, count: W * H * 3)
do {
    var buf = [UInt8](repeating: 0, count: W * H * 4)
    let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let crop = shot.cropping(to: CGRect(x: 0, y: 0, width: Double(shot.width), height: (bandPt * ss).rounded()))!
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: W, height: H))
    for i in 0..<(W * H) { for c in 0..<3 { px[i * 3 + c] = Float(buf[i * 4 + c]) } }
}
// rows in buf are top-to-bottom (CGContext memory order) -> y=0 is the top of the screen
let x0 = Int(940 * k)                         // only care about the area right of the notch
func basis(_ x: Int, _ y: Int) -> [Double] { let u = Double(x) / Double(W), v = Double(y) / Double(H); return [1, u, v, u*u, u*v, v*v, u*u*u] }
var mask = [Bool](repeating: false, count: W * H)
var coef = [[Double]](repeating: [Double](repeating: 0, count: 7), count: 3)
for _ in 0..<5 {                              // robust fit: least squares, reject outliers, repeat
    for c in 0..<3 {
        var ata = [Double](repeating: 0, count: 49), atb = [Double](repeating: 0, count: 7)
        for y in stride(from: 1, to: H - 1, by: 1) { for x in stride(from: x0, to: W, by: 2) where !mask[y * W + x] {
            let b = basis(x, y), val = Double(px[(y * W + x) * 3 + c])
            for i in 0..<7 { atb[i] += b[i] * val; for j in 0..<7 { ata[i * 7 + j] += b[i] * b[j] } } } }
        // solve 7x7 via Gaussian elimination
        var A = ata, bb = atb
        for i in 0..<7 { var p = i; for r in i..<7 where abs(A[r*7+i]) > abs(A[p*7+i]) { p = r }
            if p != i { for j in 0..<7 { A.swapAt(i*7+j, p*7+j) }; bb.swapAt(i, p) }
            for r in (i+1)..<7 { let f = A[r*7+i] / A[i*7+i]; for j in i..<7 { A[r*7+j] -= f * A[i*7+j] }; bb[r] -= f * bb[i] } }
        var xs = [Double](repeating: 0, count: 7)
        for i in stride(from: 6, through: 0, by: -1) { var s = bb[i]; for j in (i+1)..<7 { s -= A[i*7+j] * xs[j] }; xs[i] = s / A[i*7+i] }
        coef[c] = xs
    }
    for y in 0..<H { for x in x0..<W { let b = basis(x, y); var bad = false
        for c in 0..<3 { var f = 0.0; for i in 0..<7 { f += coef[c][i] * b[i] }; if abs(Double(px[(y*W+x)*3+c]) - f) > 9 { bad = true } }
        mask[y * W + x] = bad } }
}
// dilate mask by 4px (2pt) to swallow anti-aliased edges and soft shadows
var dm = mask
for y in 0..<H { for x in x0..<W where mask[y * W + x] {
    for dy in -4...4 { for dx in -5...5 { let yy = y + dy, xx = x + dx; if yy >= 0, yy < H, xx >= x0, xx < W { dm[yy * W + xx] = true } } } } }
// inpaint masked runs row by row with linear interpolation between clean neighbours
var out = px
var kept = 0
for y in 0..<H {
    var x = x0
    while x < W {
        if !dm[y * W + x] { kept += 1; x += 1; continue }
        let s = x; while x < W && dm[y * W + x] { x += 1 }
        let l = s - 1, r = x
        let hasL = l >= x0, hasR = r < W
        for xi in s..<x { for c in 0..<3 {
            var fit = 0.0; let b = basis(xi, y); for i in 0..<7 { fit += coef[c][i] * b[i] }
            let lv: Float = hasL ? px[(y*W+l)*3+c] : (hasR ? px[(y*W+r)*3+c] : Float(fit))
            let rv: Float = hasR ? px[(y*W+r)*3+c] : lv
            let t = Float(xi - l) / Float(max(1, r - l))
            out[(y*W+xi)*3+c] = lv + (rv - lv) * t } }
    }
}
// soften compression noise: box blur 13px horizontally, 5px vertically
func blur(_ a: [Float], horiz: Bool, r: Int) -> [Float] {
    var b = a
    for y in 0..<H { for x in x0..<W { for c in 0..<3 { var s: Float = 0; var n: Float = 0
        for d in -r...r { let xx = horiz ? x + d : x, yy = horiz ? y : y + d
            if xx >= x0, xx < W, yy >= 0, yy < H { s += a[(yy*W+xx)*3+c]; n += 1 } }
        b[(y*W+x)*3+c] = s / n } } }
    return b
}
out = blur(blur(out, horiz: true, r: 6), horiz: false, r: 2)
var rgba = [UInt8](repeating: 255, count: W * H * 4)
for i in 0..<(W * H) { for c in 0..<3 { rgba[i*4+c] = UInt8(max(0, min(255, out[i*3+c].rounded()))) } }
let ctx = CGContext(data: &rgba, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dst, ctx.makeImage()!, nil); CGImageDestinationFinalize(dst)
print("band \(W)x\(H) px, clean pixels kept: \(kept) of \((W - x0) * H)")
