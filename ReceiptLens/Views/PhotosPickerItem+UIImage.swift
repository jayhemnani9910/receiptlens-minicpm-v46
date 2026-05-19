import PhotosUI
import UIKit

extension PhotosPickerItem {
    func loadUIImage() async throws -> UIImage? {
        guard let data = try await loadTransferable(type: Data.self) else {
            return nil
        }
        return UIImage(data: data)
    }
}

