// MARK: - Apple Intelligence & macOS Human Interface Design Palette

enum AppleDesign {
    // Apple Intelligence Display P3 Wide-Gamut Palette
    static let siriCyan    = NSColor(displayP3Red: 0.00, green: 0.82, blue: 1.00, alpha: 1.0) // #00D1FF
    static let siriIndigo  = NSColor(displayP3Red: 0.44, green: 0.24, blue: 0.96, alpha: 1.0) // #703DF5
    static let siriMagenta = NSColor(displayP3Red: 1.00, green: 0.20, blue: 0.60, alpha: 1.0) // #FF3399
    static let siriAmber   = NSColor(displayP3Red: 1.00, green: 0.65, blue: 0.12, alpha: 1.0) // #FFA61F
    static let appleGreen  = NSColor(displayP3Red: 0.19, green: 0.82, blue: 0.35, alpha: 1.0) // #30D158 (Apple systemGreen)
    static let appleCoral  = NSColor(displayP3Red: 1.00, green: 0.27, blue: 0.23, alpha: 1.0) // #FF453A
    static let appleGold   = NSColor(displayP3Red: 1.00, green: 0.80, blue: 0.00, alpha: 1.0) // #FFCC00

    // Google brand palette (notch glow). White must be EXACTLY achromatic (equal
    // components -> OKLab chroma 0) so googleSpectrum's fades through it are pure
    // desaturation with no hue discontinuity at the segment boundaries.
    static let googleBlue   = NSColor(displayP3Red: 0.259, green: 0.522, blue: 0.957, alpha: 1.0) // #4285F4
    static let googleRed    = NSColor(displayP3Red: 0.918, green: 0.263, blue: 0.208, alpha: 1.0) // #EA4335
    static let googleYellow = NSColor(displayP3Red: 0.984, green: 0.737, blue: 0.016, alpha: 1.0) // #FBBC04
    static let googleGreen  = NSColor(displayP3Red: 0.204, green: 0.659, blue: 0.325, alpha: 1.0) // #34A853
    static let googleWhite  = NSColor(displayP3Red: 0.970, green: 0.970, blue: 0.970, alpha: 1.0)

    // MARK: OKLCH interpolation (Ottosson's OKLab, pure math - no dependencies)
    //
    // The chromatic loop interpolates in OKLCH rather than raw P3 RGB: straight RGB lerps
    // between distant hues dip through darker, muddier midpoints, while OKLCH holds perceived
    // lightness and chroma constant and swings hue along the shortest arc - the gradient stays
    // equally luminous the whole way around. Anchors remain authored as Display P3 values.

    struct OKLCh {
        let L: CGFloat
        let C: CGFloat
        let h: CGFloat // radians
    }

    private static func srgbToLinear(_ c: CGFloat) -> CGFloat {
        let sign: CGFloat = c < 0 ? -1 : 1
        let v = abs(c)
        return sign * (v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4))
    }

    private static func linearToSrgb(_ c: CGFloat) -> CGFloat {
        let sign: CGFloat = c < 0 ? -1 : 1
        let v = abs(c)
        return sign * (v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055)
    }

    private static func signedCbrt(_ v: CGFloat) -> CGFloat {
        v < 0 ? -pow(-v, 1.0 / 3.0) : pow(v, 1.0 / 3.0)
    }

    // Wide-gamut anchors are carried through extended sRGB (components may leave 0...1),
    // which the OKLab linear algebra handles without gamut clipping.
    static func toOKLCh(_ color: NSColor) -> OKLCh {
        let c = color.usingColorSpace(.extendedSRGB) ?? color
        let r = srgbToLinear(c.redComponent)
        let g = srgbToLinear(c.greenComponent)
        let b = srgbToLinear(c.blueComponent)

        let l = signedCbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = signedCbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = signedCbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s

        return OKLCh(L: L, C: sqrt(a * a + bb * bb), h: atan2(bb, a))
    }

    static func fromOKLCh(_ lch: OKLCh) -> NSColor {
        let a = lch.C * cos(lch.h)
        let bb = lch.C * sin(lch.h)

        let l = pow(lch.L + 0.3963377774 * a + 0.2158037573 * bb, 3)
        let m = pow(lch.L - 0.1055613458 * a - 0.0638541728 * bb, 3)
        let s = pow(lch.L - 0.0894841775 * a - 1.2914855480 * bb, 3)

        let r = linearToSrgb( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)
        let g = linearToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)
        let b = linearToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)

        return NSColor(colorSpace: .extendedSRGB, components: [r, g, b, 1.0], count: 4)
    }

    // Anchor stops converted once; siriSpectrum below is pure math per call.
    private static let spectrumAnchors: [OKLCh] = [siriCyan, siriIndigo, siriMagenta, siriAmber].map(toOKLCh)

    private static let googleAnchors: [OKLCh] = [googleBlue, googleRed, googleYellow, googleGreen, googleWhite].map(toOKLCh)

    // One Google color at a time: each anchor DWELLS as a solid hue for most of its
    // segment, then eases into the next (blue -> red -> yellow -> green -> white -> blue).
    // This is deliberately the opposite of siriSpectrum, which spreads all hues across
    // space at once; here the spectrum is distributed across time.
    static func googleSpectrum(at t: CGFloat) -> NSColor {
        let wrapped = t.truncatingRemainder(dividingBy: 1.0)
        let count = googleAnchors.count
        let pos = (wrapped < 0 ? wrapped + 1.0 : wrapped) * CGFloat(count)
        let seg = Int(pos) % count
        var frac = pos - CGFloat(Int(pos))

        let dwell: CGFloat = 0.60
        if frac <= dwell {
            frac = 0
        } else {
            let f = (frac - dwell) / (1.0 - dwell)
            frac = f * f * (3 - 2 * f) // smoothstep: no visible seam at either end of the fade
        }

        let c1 = googleAnchors[seg]
        let c2 = googleAnchors[(seg + 1) % count]

        // White is achromatic, so its stored hue is numerically arbitrary; borrow the
        // chromatic endpoint's hue so the fade is a pure desaturation, not a hue swing.
        var h1 = c1.h
        var h2 = c2.h
        if c1.C < 0.02 { h1 = h2 }
        if c2.C < 0.02 { h2 = h1 }
        var dh = h2 - h1
        if dh > .pi { dh -= 2 * .pi }
        if dh < -.pi { dh += 2 * .pi }

        return fromOKLCh(OKLCh(
            L: c1.L + (c2.L - c1.L) * frac,
            C: c1.C + (c2.C - c1.C) * frac,
            h: h1 + dh * frac
        ))
    }

    // Continuous Apple Intelligence 4-phase chromatic loop: Cyan -> Indigo -> Magenta -> Amber -> Cyan
    static func siriSpectrum(at t: CGFloat) -> NSColor {
        let wrapped = t.truncatingRemainder(dividingBy: 1.0)
        let pos = (wrapped < 0 ? wrapped + 1.0 : wrapped) * 4.0
        let seg = Int(pos) % 4
        let frac = pos - CGFloat(Int(pos))

        let c1 = spectrumAnchors[seg]
        let c2 = spectrumAnchors[(seg + 1) % 4]

        // Shortest-arc hue interpolation keeps the loop from detouring through the far
        // side of the hue wheel between adjacent anchors.
        var dh = c2.h - c1.h
        if dh > .pi { dh -= 2 * .pi }
        if dh < -.pi { dh += 2 * .pi }

        return fromOKLCh(OKLCh(
            L: c1.L + (c2.L - c1.L) * frac,
            C: c1.C + (c2.C - c1.C) * frac,
            h: c1.h + dh * frac
        ))
    }
}

