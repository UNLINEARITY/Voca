// Voca — a macOS menu bar app for saving selected text globally.
// Copyright (C) 2026 UNLINEARITY <https://github.com/UNLINEARITY>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
// or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public
// License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Carbon.HIToolbox
import SceneKit
import SwiftUI
import simd

struct GalaxySphereView: NSViewRepresentable {
    @ObservedObject var model: GalaxyModel
    let reverseRotation: Bool

    func makeCoordinator() -> GalaxySceneCoordinator {
        GalaxySceneCoordinator(model: model)
    }

    func makeNSView(context: Context) -> GalaxySceneView {
        let view = GalaxySceneView(frame: .zero)
        context.coordinator.attach(to: view)
        context.coordinator.update(
            items: model.items,
            fontScale: model.fontScale,
            selectedID: model.selectedItem?.clipId,
            reverseRotation: reverseRotation
        )
        return view
    }

    func updateNSView(_ view: GalaxySceneView, context: Context) {
        context.coordinator.update(
            items: model.items,
            fontScale: model.fontScale,
            selectedID: model.selectedItem?.clipId,
            reverseRotation: reverseRotation
        )
    }

    static func dismantleNSView(_ view: GalaxySceneView, coordinator: GalaxySceneCoordinator) {
        coordinator.stop()
    }
}

final class GalaxySceneView: SCNView {
    weak var interactionCoordinator: GalaxySceneCoordinator?
    private var mouseDownPoint: CGPoint?
    private var didDrag = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        didDrag = false
        interactionCoordinator?.beginDrag(at: point, time: event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let mouseDownPoint, hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 3 {
            didDrag = true
        }
        if didDrag {
            interactionCoordinator?.drag(to: point, time: event.timestamp)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        interactionCoordinator?.endDrag()
        if !didDrag {
            interactionCoordinator?.select(at: point, in: self)
        }
        mouseDownPoint = nil
        didDrag = false
    }

    override func keyDown(with event: NSEvent) {
        // 回车:折射模式 → 聚焦检索框;其他模式 → 编辑选中词条
        if event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter {
            if interactionCoordinator?.model?.source == .refraction {
                interactionCoordinator?.focusSearchField()
            } else {
                interactionCoordinator?.editSelection()
            }
            return
        }
        // Shift+Option/Command+←/→ 的源切换由 GalaxyView 的本地事件监听统一处理,
        // 对球面、检索框(含输入法激活)等任意焦点状态一致生效
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // Discrete wheel events have no gesture phase. Precise, phase-bearing
        // scrolls rotate the sphere; momentum is handled by our own inertia.
        guard event.momentumPhase == [] else { return }
        if event.phase == [] {
            guard event.scrollingDeltaY != 0 else { return }
            let sensitivity = event.hasPreciseScrollingDeltas ? 0.006 : 0.075
            interactionCoordinator?.zoom(by: exp(event.scrollingDeltaY * sensitivity))
            return
        }
        guard event.hasPreciseScrollingDeltas else { return }
        // Natural scrolling can invert AppKit's deltas; use physical finger motion.
        let deviceDirection: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        switch event.phase {
        case .began:
            interactionCoordinator?.beginSwipe()
            interactionCoordinator?.swipe(
                byX: event.scrollingDeltaX * deviceDirection,
                y: event.scrollingDeltaY * deviceDirection,
                time: event.timestamp
            )
        case .changed:
            interactionCoordinator?.swipe(
                byX: event.scrollingDeltaX * deviceDirection,
                y: event.scrollingDeltaY * deviceDirection,
                time: event.timestamp
            )
        case .ended, .cancelled:
            interactionCoordinator?.endSwipe()
        default:
            break
        }
    }

    override func magnify(with event: NSEvent) {
        interactionCoordinator?.zoom(by: max(0.1, 1 + event.magnification * 1.2))
    }

    func pauseRendering() {
        interactionCoordinator?.stop()
    }

    func resumeRendering() {
        interactionCoordinator?.resume()
    }
}

@MainActor
final class GalaxySceneCoordinator: NSObject {
    private static let sphereRadius: CGFloat = 1.48
    private static let baseAutoRotate: Float = 0.06
    private static let selectedLift: Float = 0.09

    private struct RenderedLabel {
        let item: GalaxyItem
        let geometryCenter: SIMD3<Float>
        let node: SCNNode
    }

    weak var model: GalaxyModel?
    private weak var view: GalaxySceneView?
    private let scene = SCNScene()
    private let rotatingRoot = SCNNode()
    private let labelsRoot = SCNNode()
    private var labels: [Int64: RenderedLabel] = [:]
    private var timer: Timer?
    private var latestItems: [GalaxyItem] = []
    private var renderedSignature: Int?
    private var appliedFontScale: Double?
    private var selectedID: Int64?
    private var reverseRotation = false

    private var yaw: Float = 0.18
    private var pitch: Float = -0.08
    private var yawVelocity = GalaxySceneCoordinator.baseAutoRotate
    private var pitchVelocity: Float = 0
    private var lastFrameTime: TimeInterval?
    private var lastDrag: (point: CGPoint, time: TimeInterval)?
    private var isSwiping = false
    private var lastSwipeTime: TimeInterval?

    init(model: GalaxyModel) {
        self.model = model
        super.init()
        configureScene()
    }

    func attach(to view: GalaxySceneView) {
        self.view = view
        view.interactionCoordinator = self
        view.scene = scene
        view.pointOfView = scene.rootNode.childNodes.first { $0.camera != nil }
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.isPlaying = true
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastFrameTime = nil
        lastDrag = nil
        isSwiping = false
        lastSwipeTime = nil
        view?.isPlaying = false
    }

    func resume() {
        guard timer == nil else { return }
        lastFrameTime = nil
        view?.isPlaying = true
        startTimer()
    }

    func update(
        items: [GalaxyItem],
        fontScale: Double,
        selectedID: Int64?,
        reverseRotation: Bool
    ) {
        latestItems = items
        if self.reverseRotation != reverseRotation {
            self.reverseRotation = reverseRotation
            yawVelocity = selectedID == nil ? Self.baseAutoRotate : 0
            pitchVelocity = 0
        }
        let signature = itemSignature(items)
        var didRebuild = false
        if renderedSignature != signature {
            if isSourceTransitioning {
                // 旋转更替进行中:重建统一由动画回调执行,
                // 避免中途无动画重建造成词条半透明闪现
            } else if let forward = model?.pendingSourceSwitch {
                model?.pendingSourceSwitch = nil
                beginSpinTransition(forward: forward)
            } else if canRelayout(items) {
                animateLayout(items: items, signature: signature)
            } else {
                rebuild(items: items, signature: signature)
                didRebuild = true
            }
        }
        let selectionChanged = self.selectedID != selectedID
        updateSelection(selectedID)
        if didRebuild || selectionChanged || appliedFontScale != fontScale {
            applyTextScale(fontScale)
            appliedFontScale = fontScale
        }
    }

    func beginDrag(at point: CGPoint, time: TimeInterval) {
        lastDrag = (point, time)
    }

    func drag(to point: CGPoint, time: TimeInterval) {
        guard let previous = lastDrag else {
            lastDrag = (point, time)
            return
        }
        let deltaX = Float(point.x - previous.point.x)
        let deltaY = Float(point.y - previous.point.y)
        let deltaTime = max(0.008, time - previous.time)
        let direction: Float = reverseRotation ? -1 : 1
        let yawDelta = deltaX * 0.005 * direction
        let pitchDelta = -deltaY * 0.005 * direction
        yaw += yawDelta
        pitch = min(max(pitch + pitchDelta, -1.35), 1.35)
        yawVelocity = yawDelta / Float(deltaTime)
        pitchVelocity = pitchDelta / Float(deltaTime)
        lastDrag = (point, time)
        applyRotation()
    }

    func endDrag() {
        lastDrag = nil
        yawVelocity = min(max(yawVelocity, -4), 4)
        pitchVelocity = min(max(pitchVelocity, -4), 4)
    }

    func beginSwipe() {
        isSwiping = true
        lastSwipeTime = nil
    }

    func swipe(byX deltaX: CGFloat, y deltaY: CGFloat, time: TimeInterval) {
        guard isSwiping else { return }
        let deltaTime = Float(max(0.008, lastSwipeTime.map { time - $0 } ?? 1.0 / 60.0))
        let direction: Float = reverseRotation ? -1 : 1
        let yawDelta = Float(deltaX) * 0.003 * direction
        let pitchDelta = -Float(deltaY) * 0.003 * direction
        yaw += yawDelta
        pitch = min(max(pitch + pitchDelta, -1.35), 1.35)
        yawVelocity = yawVelocity * 0.65 + (yawDelta / deltaTime) * 0.35
        pitchVelocity = pitchVelocity * 0.65 + (pitchDelta / deltaTime) * 0.35
        lastSwipeTime = time
        applyRotation()
    }

    func endSwipe() {
        isSwiping = false
        lastSwipeTime = nil
        yawVelocity = min(max(yawVelocity, -4), 4)
        pitchVelocity = min(max(pitchVelocity, -4), 4)
    }

    func zoom(by factor: Double) {
        model?.zoom(by: factor)
    }

    func select(at point: CGPoint, in view: SCNView) {
        let options: [SCNHitTestOption: Any] = [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .backFaceCulling: true,
        ]
        let clipID = view.hitTest(point, options: options).lazy.compactMap { result in
            self.clipID(from: result.node)
        }.first
        model?.selectedItem = clipID.flatMap { id in
            latestItems.first { $0.clipId == id }
        }
    }

    /// 选中词条后按回车 → 发出编辑请求(GalaxyView 弹编辑面板;剪贴板条目无编辑界面,忽略)
    func editSelection() {
        guard let item = model?.selectedItem else { return }
        model?.pendingEdit = item
    }

    /// 折射模式下聚焦检索框:直接定位窗口内唯一的可编辑文本控件(SwiftUI TextField
    /// 的宿主 NSTextField)并设为 first responder,同步完成、不依赖焦点接力
    func focusSearchField() {
        guard let model, model.source == .refraction,
              let window = view?.window,
              let field = firstEditableTextField(in: window.contentView)
        else { return }
        window.makeFirstResponder(field)
    }

    private func firstEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let found = firstEditableTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - 源切换旋转更替(球壳圆形对称保持不动,动效仅在词条层)

    private var isSourceTransitioning = false
    /// 切换时的角速度冲量(rad/s;经惯性系统自然衰减,约转 1/3 圈)
    private static let sourceSpinImpulse: Float = 7

    private func beginSpinTransition(forward: Bool) {
        isSourceTransitioning = true
        model?.pendingSourceSwitch = nil
        // 1) 旋转冲量:方向跟随按键;惯性系统会让它自然减速回怠速自转
        yawVelocity = forward ? Self.sourceSpinImpulse : -Self.sourceSpinImpulse
        pitchVelocity = 0
        // 2) 旧词条群:短暂停留后边转边淡出
        labelsRoot.runAction(.sequence([
            .wait(duration: 0.10),
            .fadeOpacity(to: 0, duration: 0.15),
            // SCNAction 回调上下文非隔离:回主线程后再做重建与状态复位
            .run { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.finishSpinTransition()
                    }
                }
            },
        ]))
    }

    /// 淡出中点:以当时的最新 items 重建并淡入(动画期间到达的全部 update 已被挂起,
    /// 此处是唯一重建点,消除双重建竞态造成的闪现)
    private func finishSpinTransition() {
        guard isSourceTransitioning else { return }
        let items = latestItems
        rebuild(items: items, signature: itemSignature(items))
        if let fontScale = appliedFontScale {
            applyTextScale(fontScale)
        }
        labelsRoot.opacity = 0
        labelsRoot.runAction(.sequence([
            .fadeOpacity(to: 1, duration: 0.20),
            .run { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.isSourceTransitioning = false
                        self?.model?.pendingSourceSwitch = nil
                    }
                }
            },
        ]))
    }

    private func configureScene() {
        scene.background.contents = NSColor.clear

        let camera = SCNCamera()
        camera.fieldOfView = 39
        camera.zNear = 0.1
        camera.zFar = 100
        camera.wantsHDR = true
        camera.bloomIntensity = 0.08
        camera.bloomThreshold = 1.2
        camera.bloomBlurRadius = 5
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 4.7)
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(calibratedWhite: 0.72, alpha: 1)
        ambient.intensity = 110
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        scene.rootNode.addChildNode(rotatingRoot)
        rotatingRoot.addChildNode(labelsRoot)
        applyRotation()
    }

    private func rebuild(items: [GalaxyItem], signature: Int) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        labelsRoot.childNodes.forEach { $0.removeFromParentNode() }
        labels.removeAll(keepingCapacity: true)

        for item in items where !item.text.isEmpty {
            let layout = makeLayout(for: item)
            let node = makeTextNode(
                item: item,
                text: layout.text,
                renderFontSize: layout.renderFontSize,
                angularWidth: layout.angularWidth,
                angularHeight: layout.angularHeight
            )
            node.opacity = selectedID == nil || item.clipId == selectedID ? 1 : 0.38
            node.simdPosition = item.clipId == selectedID
                ? simd_normalize(item.position) * Self.selectedLift : .zero
            labelsRoot.addChildNode(node)
            labels[item.clipId] = RenderedLabel(
                item: item,
                geometryCenter: item.position,
                node: node
            )
        }
        SCNTransaction.commit()

        renderedSignature = signature
    }

    private func canRelayout(_ items: [GalaxyItem]) -> Bool {
        let drawable = items.filter { !$0.text.isEmpty }
        guard drawable.count == labels.count else { return false }
        return drawable.allSatisfy { item in
            guard let old = labels[item.clipId] else { return false }
            return old.item.text == item.text && old.item.fontSize == item.fontSize
        }
    }

    private func animateLayout(items: [GalaxyItem], signature: Int) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.38
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        for item in items where !item.text.isEmpty {
            guard let old = labels[item.clipId] else { continue }
            old.node.simdOrientation = orientation(from: old.geometryCenter, to: item.position)
            old.node.simdPosition = item.clipId == selectedID
                ? simd_normalize(item.position) * Self.selectedLift : .zero
            labels[item.clipId] = RenderedLabel(
                item: item,
                geometryCenter: old.geometryCenter,
                node: old.node
            )
        }
        SCNTransaction.commit()
        renderedSignature = signature
    }

    private func orientation(from original: SIMD3<Float>, to target: SIMD3<Float>) -> simd_quatf {
        func basis(_ position: SIMD3<Float>) -> simd_float3x3 {
            let center = simd_normalize(position)
            let east = simd_normalize(SIMD3(center.z, 0, -center.x))
            let north = simd_normalize(simd_cross(center, east))
            return simd_float3x3(columns: (east, north, center))
        }
        return simd_quatf(basis(target) * simd_transpose(basis(original)))
    }

    private func applyTextScale(_ scale: Double) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.18
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        for (clipID, label) in labels {
            let emphasis = clipID == selectedID ? 1.12 : 1.0
            let textScale = min(max(scale * emphasis, 0.5), 2.5)
            let smallWeight = textScale < 1 ? CGFloat((1 - textScale) / 0.5) : 0
            let largeWeight = textScale > 1 ? CGFloat((textScale - 1) / 1.5) : 0
            label.node.morpher?.setWeight(smallWeight, forTargetAt: 0)
            label.node.morpher?.setWeight(largeWeight, forTargetAt: 1)
        }
        SCNTransaction.commit()
    }

    private func updateSelection(_ newSelection: Int64?) {
        guard selectedID != newSelection else { return }
        selectedID = newSelection

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.24
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        for (clipID, label) in labels {
            label.node.opacity = newSelection == nil || clipID == newSelection ? 1 : 0.38
            label.node.simdPosition = clipID == newSelection
                ? simd_normalize(label.item.position) * Self.selectedLift : .zero
        }
        SCNTransaction.commit()
    }

    private func makeLayout(
        for item: GalaxyItem
    ) -> (text: String, renderFontSize: CGFloat, angularWidth: Float, angularHeight: Float) {
        let text = item.sphereText
        let angularHeight = item.angularHeight
        let renderFontSize = max(42, item.fontSize * 3)
        let image = textImage(text, fontSize: renderFontSize)
        let aspectRatio = Float(image.size.width / max(1, image.size.height))
        return (
            text,
            renderFontSize,
            min(GalaxyItem.maximumTextAngle, aspectRatio * angularHeight),
            angularHeight
        )
    }

    private func makeTextNode(
        item: GalaxyItem,
        text: String,
        renderFontSize: CGFloat,
        angularWidth: Float,
        angularHeight: Float
    ) -> SCNNode {
        let segments = max(12, min(96, text.count * 2))
        let geometry = makeRibbonGeometry(
            center: item.position,
            angularWidth: angularWidth,
            angularHeight: angularHeight,
            segments: segments
        )
        geometry.firstMaterial = makeTextMaterial(
            text: text,
            fontSize: renderFontSize
        )

        let morpher = SCNMorpher()
        morpher.calculationMode = .normalized
        morpher.unifiesNormals = true
        morpher.targets = [
            makeRibbonGeometry(
                center: item.position,
                angularWidth: angularWidth * 0.5,
                angularHeight: angularHeight * 0.5,
                segments: segments
            ),
            makeRibbonGeometry(
                center: item.position,
                angularWidth: angularWidth * 2.5,
                angularHeight: angularHeight * 2.5,
                segments: segments
            ),
        ]

        let node = SCNNode(geometry: geometry)
        node.morpher = morpher
        node.name = "galaxy.label.\(item.clipId)"
        node.renderingOrder = 10
        return node
    }

    private func makeRibbonGeometry(
        center rawCenter: SIMD3<Float>,
        angularWidth: Float,
        angularHeight: Float,
        segments: Int
    ) -> SCNGeometry {
        let center = simd_normalize(rawCenter)
        var east = SIMD3<Float>(center.z, 0, -center.x)
        if simd_length(east) < 0.001 {
            east = SIMD3(1, 0, 0)
        }
        east = simd_normalize(east)

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var textureCoordinates: [CGPoint] = []
        vertices.reserveCapacity((segments + 1) * 2)
        normals.reserveCapacity((segments + 1) * 2)
        textureCoordinates.reserveCapacity((segments + 1) * 2)

        for column in 0...segments {
            let textureX = Float(column) / Float(segments)
            let horizontalAngle = (textureX - 0.5) * angularWidth
            let base = simd_normalize(
                center * cos(horizontalAngle) + east * sin(horizontalAngle)
            )
            let horizontalTangent = simd_normalize(
                -center * sin(horizontalAngle) + east * cos(horizontalAngle)
            )
            let north = simd_normalize(simd_cross(base, horizontalTangent))

            for row in 0...1 {
                let textureY = Float(row)
                let verticalAngle = (textureY - 0.5) * angularHeight
                let surface = simd_normalize(
                    base * cos(verticalAngle) + north * sin(verticalAngle)
                )
                let position = surface * Float(Self.sphereRadius * 1.008)
                vertices.append(SCNVector3(position.x, position.y, position.z))
                normals.append(SCNVector3(surface.x, surface.y, surface.z))
                textureCoordinates.append(
                    CGPoint(x: CGFloat(textureX), y: CGFloat(1 - textureY))
                )
            }
        }

        var indices: [Int32] = []
        indices.reserveCapacity(segments * 6)
        for column in 0..<segments {
            let lower = Int32(column * 2)
            let next = lower + 2
            indices.append(contentsOf: [
                lower, next, lower + 1,
                lower + 1, next, next + 1,
            ])
        }

        let sources = [
            SCNGeometrySource(vertices: vertices),
            SCNGeometrySource(normals: normals),
            SCNGeometrySource(textureCoordinates: textureCoordinates),
        ]
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: sources, elements: [element])
    }

    private func makeTextMaterial(
        text: String,
        fontSize: CGFloat
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = textImage(text, fontSize: fontSize)
        material.diffuse.magnificationFilter = .linear
        material.diffuse.minificationFilter = .linear
        material.diffuse.mipFilter = .linear
        material.transparencyMode = .aOne
        material.blendMode = .alpha
        material.isDoubleSided = false
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        return material
    }

    private func textImage(_ text: String, fontSize: CGFloat) -> NSImage {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.78)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.89, alpha: 1),
            .strokeColor: NSColor(calibratedWhite: 0.08, alpha: 0.94),
            .strokeWidth: -4.5,
            .shadow: shadow,
        ]
        let measuredSize = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 8
        let image = NSImage(
            size: CGSize(
                width: ceil(measuredSize.width + padding * 2),
                height: ceil(measuredSize.height + padding * 2)
            )
        )
        image.lockFocus()
        (text as NSString).draw(
            at: CGPoint(x: padding, y: padding),
            withAttributes: attributes
        )
        image.unlockFocus()
        return image
    }

    private func clipID(from node: SCNNode) -> Int64? {
        var currentNode: SCNNode? = node
        while let current = currentNode {
            if let name = current.name,
               name.hasPrefix("galaxy.label."),
               let value = Int64(name.dropFirst("galaxy.label.".count)) {
                return value
            }
            currentNode = current.parent
        }
        return nil
    }

    private func itemSignature(_ items: [GalaxyItem]) -> Int {
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.clipId)
            hasher.combine(item.text)
            hasher.combine(item.fontSize)
            hasher.combine(item.position.x)
            hasher.combine(item.position.y)
            hasher.combine(item.position.z)
        }
        return hasher.finalize()
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advanceFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = Float(min(0.05, lastFrameTime.map { now - $0 } ?? 1.0 / 60.0))
        lastFrameTime = now

        if isSwiping, let lastSwipeTime, now - lastSwipeTime > 0.2 {
            endSwipe()
        }
        guard lastDrag == nil, !isSwiping else { return }
        yaw += yawVelocity * delta
        pitch = min(max(pitch + pitchVelocity * delta, -1.35), 1.35)

        if selectedID != nil {
            yawVelocity *= pow(0.0001, delta)
            pitchVelocity *= pow(0.0001, delta)
        } else {
            yawVelocity = Self.baseAutoRotate
                + (yawVelocity - Self.baseAutoRotate) * pow(0.05, delta)
            pitchVelocity *= pow(0.02, delta)
        }
        applyRotation()
    }

    private func applyRotation() {
        let yawRotation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let pitchRotation = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
        rotatingRoot.simdOrientation = pitchRotation * yawRotation
    }

}
