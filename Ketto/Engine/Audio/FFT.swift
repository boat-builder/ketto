import Foundation

/// An in-place radix-2 complex FFT. Written in plain Swift rather than on vDSP so the noise reducer is
/// deterministic, testable anywhere, and free of the real-FFT packing conventions that are easy to get
/// subtly wrong. A 1024-point transform costs a few microseconds at -O, which is plenty for offline audio.
struct FFT: Sendable {
    let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let reversed: [Int]

    /// `size` must be a power of two, at least 2.
    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        var cosTable = [Float](repeating: 0, count: size / 2)
        var sinTable = [Float](repeating: 0, count: size / 2)
        for i in 0..<size / 2 {
            let angle = 2 * Double.pi * Double(i) / Double(size)
            cosTable[i] = Float(cos(angle))
            sinTable[i] = Float(sin(angle))
        }
        let bits = size.trailingZeroBitCount
        var reversed = [Int](repeating: 0, count: size)
        for i in 0..<size {
            var value = i
            var result = 0
            for _ in 0..<bits {
                result = (result << 1) | (value & 1)
                value >>= 1
            }
            reversed[i] = result
        }
        self.cosTable = cosTable
        self.sinTable = sinTable
        self.reversed = reversed
    }

    /// Forward transform, unscaled: `X[k] = Σ x[n] e^{-2πi kn/N}`.
    func forward(real: inout [Float], imag: inout [Float]) {
        transform(real: &real, imag: &imag, inverse: false)
    }

    /// Inverse transform, scaled by `1/N`, so `inverse(forward(x)) == x`.
    func inverse(real: inout [Float], imag: inout [Float]) {
        transform(real: &real, imag: &imag, inverse: true)
    }

    private func transform(real: inout [Float], imag: inout [Float], inverse: Bool) {
        let n = size
        precondition(real.count == n && imag.count == n, "FFT buffers must match the transform size")
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                for i in 0..<n {
                    let j = reversed[i]
                    if j > i {
                        re.swapAt(i, j)
                        im.swapAt(i, j)
                    }
                }
                var length = 2
                while length <= n {
                    let half = length / 2
                    let step = n / length
                    var start = 0
                    while start < n {
                        var k = 0
                        for j in 0..<half {
                            let wr = cosTable[k]
                            let wi = inverse ? sinTable[k] : -sinTable[k]
                            let a = start + j
                            let b = a + half
                            let tr = re[b] * wr - im[b] * wi
                            let ti = re[b] * wi + im[b] * wr
                            re[b] = re[a] - tr
                            im[b] = im[a] - ti
                            re[a] += tr
                            im[a] += ti
                            k += step
                        }
                        start += length
                    }
                    length <<= 1
                }
                if inverse {
                    let scale = 1 / Float(n)
                    for i in 0..<n {
                        re[i] *= scale
                        im[i] *= scale
                    }
                }
            }
        }
    }
}
