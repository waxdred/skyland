import Common

class MacosFullscreenWindowsContainer: TreeNode, NonLeafTreeNodeObject {
    init(parent: Workspace) {
        super.init(parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }
}
