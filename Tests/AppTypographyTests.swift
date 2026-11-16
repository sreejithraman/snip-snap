import CoreText
import SwiftUI
import XCTest
#if os(macOS)
@testable import SnipSnap
#else
import UIKit
@testable import SnipSnapiOS
#endif

final class AppTypographyTests: XCTestCase {
    func testInterfaceFontLoadsBundledAllo() {
        let font = AppTypography.font(.body, in: EnvironmentValues().fontResolutionContext).resolve(in: EnvironmentValues().fontResolutionContext).ctFont
        XCTAssertEqual(CTFontCopyFamilyName(font) as String, "Allo")
    }

    func testNamedWeightsAndInheritedEmphasisStayDistinct() {
        let context = EnvironmentValues().fontResolutionContext
        let regular = AppTypography.font(.body, in: context).resolve(in: context).ctFont
        let semibold = AppTypography.font(.body, weight: .semibold, in: context).resolve(in: context).ctFont
        let bold = AppTypography.font(.body, in: context).weight(.bold).resolve(in: context).ctFont
        XCTAssertEqual(CTFontCopyFamilyName(semibold) as String, "Allo")
        XCTAssertEqual(CTFontCopyFamilyName(bold) as String, "Allo")
        func weight(_ font: CTFont) -> CGFloat {
            (CTFontCopyTraits(font) as NSDictionary)[kCTFontWeightTrait] as? CGFloat ?? 0
        }
        XCTAssertGreaterThan(weight(semibold), weight(regular))
        XCTAssertGreaterThan(weight(bold), weight(semibold))
    }

    func testItalicEmphasisUsesTheBundledOblique() {
        let context = EnvironmentValues().fontResolutionContext
        for font in [AppTypography.font(.body, in: context), AppTypography.font(.body, weight: .bold, in: context)] {
            let italic = font.italic().resolve(in: context)
            XCTAssertTrue(italic.isItalic)
            XCTAssertEqual(CTFontCopyFamilyName(italic.ctFont) as String, "Allo")
            XCTAssertTrue((CTFontCopyPostScriptName(italic.ctFont) as String).hasSuffix("Oblique"))
        }
    }

    func testInterfaceAlternatesPreserveLiteralPunctuation() {
        let context = EnvironmentValues().fontResolutionContext
        for font in [AppTypography.font(.body, in: context), AppTypography.font(.body, in: context).weight(.bold), AppTypography.font(.body, in: context).italic()] {
            let resolved = font.resolve(in: context).ctFont
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "aIl10 -> 1/2 469", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): resolved]
            ))
            let names = (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run -> [String] in
                var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                return glyphs.map { CTFontCopyNameForGlyph(resolved, $0) as String? ?? "" }
            }
            XCTAssertEqual(names, [
                "a.1", "I.1", "l.ss02", "one.foot", "zero.slash", "space", "hyphen", "greater", "space",
                "one.foot", "slash", "two", "space", "four", "six", "nine"
            ])
        }
    }

    func testTabularFiguresRemainOptIn() {
        let context = EnvironmentValues().fontResolutionContext
        func width(_ text: String, font: Font) -> Double {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font.resolve(in: context).ctFont]
            ))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        let proportional = AppTypography.font(.body, in: context)
        XCTAssertNotEqual(width("1111", font: proportional), width("8888", font: proportional))
        let tabular = proportional.monospacedDigit()
        XCTAssertEqual(width("1111", font: tabular), width("8888", font: tabular), accuracy: 0.01)
    }

    func testSemanticSizingAndDynamicType() {
        var environment = EnvironmentValues()
        environment.dynamicTypeSize = .large
        let body = AppTypography.font(.body, in: environment.fontResolutionContext).resolve(in: environment.fontResolutionContext)
        let nativeBody = Font.body.resolve(in: environment.fontResolutionContext)
        XCTAssertEqual(body.pointSize, nativeBody.pointSize, accuracy: 0.1)
        XCTAssertGreaterThan(AppTypography.font(.title, in: environment.fontResolutionContext).resolve(in: environment.fontResolutionContext).pointSize, body.pointSize)
#if os(iOS)
        environment.dynamicTypeSize = .accessibility3
        XCTAssertGreaterThan(AppTypography.font(.body, in: environment.fontResolutionContext).resolve(in: environment.fontResolutionContext).pointSize, body.pointSize * 2)
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge)
        let scaled = AppTypography.preferredFont(.body, compatibleWith: traits)
        XCTAssertEqual(scaled.familyName, "Allo")
        XCTAssertGreaterThan(scaled.pointSize, 34)
#endif
    }

    @MainActor
    func testAttributedHeadingsScaleAndKeepCodeFonts() async throws {
        let content = await SnipMarkdown.prepare("# aIl10\n`literal -> 1/2`")
        var environment = EnvironmentValues()
        environment.dynamicTypeSize = .accessibility3
        let context = environment.fontResolutionContext
        let styled = AppTypography.attributedText(content.fullText, in: context)
        let heading = try XCTUnwrap(styled.runs.first?.font).resolve(in: context)
        XCTAssertEqual(CTFontCopyFamilyName(heading.ctFont) as String, "Allo")
        XCTAssertEqual(heading.pointSize, Font.body.resolve(in: context).pointSize, accuracy: 0.1)
        XCTAssertEqual(CTFontCopyPostScriptName(heading.ctFont) as String, "Allo-SemiBold")
#if os(iOS)
        XCTAssertGreaterThan(heading.pointSize, 34)
#endif
        let code = styled.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertEqual(code?.font, Font.body.monospaced())
        XCTAssertEqual(String(styled.characters), "aIl10\nliteral -> 1/2")
    }

    func testMissingScriptsUseNativeFallback() {
        let context = EnvironmentValues().fontResolutionContext
        let font = AppTypography.font(.body, in: context).resolve(in: context).ctFont
        let fallback = CTFontCreateForString(font, "日本語" as CFString, CFRange(location: 0, length: 3))
        XCTAssertNotEqual(CTFontCopyFamilyName(fallback) as String, "Allo")
    }
}
