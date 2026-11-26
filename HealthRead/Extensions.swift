//
// For licensing see accompanying LICENSE file.
// Copyright (C) 2024 Apple Inc. All Rights Reserved.
//

import CoreImage

extension CIImage {

    /// cropToSquare image
    /// - Returns: Cropped image
    func cropToSquare() -> CIImage? {
        let size = min(self.extent.width, self.extent.height)
        let x = round((self.extent.width - size) / 2)
        let y = round((self.extent.height - size) / 2)

        let cropRect = CGRect(
            x: x,
            y: y,
            width: size,
            height: size
        )

        let translate = CGAffineTransform(translationX: -x, y: -y)

        return
            self
            .cropped(to: cropRect)
            .transformed(by: translate)
    }

    /// Resize image
    /// - Parameter size: Size to resize to
    /// - Returns: Resized image
    func resize(size: CGSize) -> CIImage? {
        let scaleX = size.width / self.extent.width
        let scaleY = size.height / self.extent.height
        return self.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }
}

import UIKit

extension UIImage {

    /// Makes a UIImage from a camera frame. Frames are already rotated to portrait
    /// by the capture connection, so no extra orientation is applied.
    static func from(pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Redraws the image upright (applying its EXIF orientation) and no larger than
    /// `maxDimension` pixels on its longest side. Library photos can be 12+ MP; the
    /// readers only need enough resolution to see the display digits.
    func normalizedForReading(maxDimension: CGFloat = 1600) -> UIImage {
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let longest = max(pixelSize.width, pixelSize.height)
        let factor = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: (pixelSize.width * factor).rounded(), height: (pixelSize.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
