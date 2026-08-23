#if os(macOS) && canImport(WhisperKit)
import XCTest
@testable import v2s

final class TibetanASREngineTests: XCTestCase {
    func testPreservesAddedTibetanTokensWhileRemovingWhisperControls() {
        let decoded = """
        <|startoftranscript|><|bo|><|transcribe|><|notimestamps|>ཁོང་གི་ཐུན་མོང་མ་ཡིན་པའི་གནང་ཕྱོགས་ཤིག་ནི།  <|endoftext|>
        """

        XCTAssertEqual(
            TibetanASREngine.sanitizedTranscript(decoded),
            "ཁོང་གི་ཐུན་མོང་མ་ཡིན་པའི་གནང་ཕྱོགས་ཤིག་ནི།"
        )
    }
}
#endif
