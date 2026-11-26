import AppKit
import SceneKit
import SwiftUI

/// Interactive SceneKit 3D viewport for orbiting and inspecting the generated `.ply` 3D Gaussian Splat / point cloud.
public struct SplatPreviewView: NSViewRepresentable {
    public let cloud: PLYPreviewCloud
    public let resetToken: Int

    public init(cloud: PLYPreviewCloud, resetToken: Int = 0) {
        self.cloud = cloud
        self.resetToken = resetToken
    }

    public func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.scene = buildScene(for: cloud)
        return view
    }

    public func updateNSView(_ nsView: SCNView, context: Context) {
        if context.coordinator.lastVertexCount != cloud.totalVertexCount
            || context.coordinator.lastResetToken != resetToken {
            nsView.scene = buildScene(for: cloud)
            context.coordinator.lastVertexCount = cloud.totalVertexCount
            context.coordinator.lastResetToken = resetToken
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public final class Coordinator {
        var lastVertexCount: Int = -1
        var lastResetToken: Int = -1
    }

    private func buildScene(for cloud: PLYPreviewCloud) -> SCNScene {
        let scene = SCNScene()

        // Camera positioned near the panorama origin in +Y Up world space looking forward (-Z)
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = 70
        camera.zNear = 0.05
        camera.zFar = 300.0
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 0.01)
        scene.rootNode.addChildNode(cameraNode)

        guard !cloud.positions.isEmpty else { return scene }

        let vertexData = cloud.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorData = cloud.colors.withUnsafeBufferPointer { Data(buffer: $0) }

        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: cloud.positions.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: cloud.colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )

        let element = SCNGeometryElement(
            data: nil,
            primitiveType: .point,
            primitiveCount: cloud.positions.count,
            bytesPerIndex: 0
        )
        element.pointSize = 3.5
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 6.0

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]

        let cloudNode = SCNNode(geometry: geometry)
        // Convert standard COLMAP RDF (+Y down, +Z forward) to SceneKit/SuperSplat (+Y up, -Z forward) via 180° X rotation
        cloudNode.eulerAngles = SCNVector3(Float.pi, 0, 0)
        scene.rootNode.addChildNode(cloudNode)

        return scene
    }
}
