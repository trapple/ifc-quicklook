// Quick Look プレビュー拡張のエントリポイント。
// ViewerViewController を埋め込み、ロードはプログレッシブに進むため
// preparePreview はビューを構築したら即座に完了を返す。
import AppKit
import Quartz

final class PreviewViewController: NSViewController, QLPreviewingController {

    private let viewer = ViewerViewController()

    override func loadView() {
        view = NSView()
        addChild(viewer)
        viewer.view.frame = view.bounds
        viewer.view.autoresizingMask = [.width, .height]
        view.addSubview(viewer.view)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        viewer.start(url: url)
        // エラーはビュー内のエラービューで表示する（Fail Fast だが QL 自体は開く。
        // throw すると QL が汎用アイコンに差し替えてしまい理由が伝わらないため）。
    }
}
