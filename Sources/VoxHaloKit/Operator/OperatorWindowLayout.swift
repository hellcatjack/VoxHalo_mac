import CoreGraphics

public enum OperatorWindowLayout {
    public static let preferredContentSize = CGSize(width: 1_020, height: 540)
    public static let minimumContentSize = CGSize(width: 900, height: 500)
    public static let horizontalScreenMargin: CGFloat = 16
    public static let verticalScreenMargin: CGFloat = 24

    public static func contentSize(fitting visibleFrame: CGRect) -> CGSize {
        let maximumWidth = max(
            1,
            visibleFrame.width - horizontalScreenMargin * 2
        )
        let maximumHeight = max(
            1,
            visibleFrame.height - verticalScreenMargin * 2
        )
        return CGSize(
            width: min(preferredContentSize.width, maximumWidth),
            height: min(preferredContentSize.height, maximumHeight)
        )
    }
}
