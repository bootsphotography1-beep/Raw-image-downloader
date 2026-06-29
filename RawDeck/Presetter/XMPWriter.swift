import Foundation

/// Generates XMP preset files using Adobe's Camera Raw schema (`crs:`).
///
/// The output format is identical to what Photoshop's "Save Settings"
/// produces for Camera Raw presets, and what Lightroom writes for
/// "User Presets" in the Develop module. Both tools can import this
/// via their Presets → Import menu.
///
/// Spec reference:
/// https://developer.adobe.com/xmp/docs/XMPNamespaces/crs/
///
/// We only emit the Basic panel sliders (the ones `PresetMapper` derives).
/// HSL / Color Grading / Calibration panels are skipped — we can't infer
/// them from a single reference image. The output is a valid XMP file
/// that any Adobe tool will load; it just won't have those panels.
enum XMPWriter {

    /// Build the XMP document as a String. Caller writes it to disk.
    static func make(name: String, preset: DerivedPreset) -> String {
        // Adobe's XMP uses crs:Exposure2012, crs:Contrast2012, etc.
        // The "2012" suffix denotes the Process Version (PV2012 / PV2020)
        // which uses the modern tone curve. We emit "2012" for max
        // compatibility — older PVs are deprecated and newer ones
        // (2020+) require newer tool versions to read.
        return """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="RawDeck LookExtractor 1.0">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
                crs:PresetType="Normal"
                crs:Cluster=""
                crs:UUID="\(uuidString())"
                crs:SupportsAmount="False"
                crs:Name="\(xmlEscape(name))"
                crs:ProcessVersion="11.0"
                crs:Exposure2012="\(preset.exposure)"
                crs:Contrast2012="\(preset.contrast)"
                crs:Highlights2012="\(preset.highlights)"
                crs:Shadows2012="\(preset.shadows)"
                crs:Whites2012="\(preset.whites)"
                crs:Blacks2012="\(preset.blacks)"
                crs:Texture="0"
                crs:Clarity2012="0"
                crs:Dehaze="0"
                crs:Vibrance="\(preset.vibrance)"
                crs:Saturation="\(preset.saturation)"
                crs:Temperature="\(preset.temperature)"
                crs:Tint="\(preset.tint)"
                crs:Sharpness="25"
                crs:SharpenRadius="+1.0"
                crs:SharpenDetail="25"
                crs:SharpenEdgeMasking="0"
                crs:LuminanceSmoothing="0"
                crs:LuminanceNoiseReductionDetail="50"
                crs:LuminanceNoiseReductionContrast="0"
                crs:ColorNoiseReduction="25"
                crs:ColorNoiseReductionDetail="50"
                crs:ColorNoiseReductionSmoothness="50"
                crs:ToneCurveName2012="Linear"
                crs:HasCrop="False"
                crs:AlreadyApplied="False" />
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// Generate a stable UUID-like string. Camera Raw uses UUIDs to
    /// distinguish presets with the same name. We use a real UUID
    /// for simplicity.
    private static func uuidString() -> String {
        return UUID().uuidString.uppercased()
    }

    /// Escape characters that have special meaning in XML. Adobe's
    /// preset name can contain user input (filenames) — must escape
    /// `<`, `>`, `&`, `"`, `'` to keep the XMP well-formed.
    private static func xmlEscape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}