import Foundation
import YoloMeetCore

extension Story {
    /// How a neural network works: a black box made of particles opens, and its particles become a brain, with the
    /// neurons and weights inside it, then some of them are laid out as a multilayer perceptron, then YOLO's
    /// architecture (backbone, neck, head) its input and output, the picture it looks at, its pixels, their red, green
    /// and blue channels, and the same picture in grayscale (one channel) or multispectral (five); then the picture
    /// flows through the model, each task's output, and a conclusion. The steps share one network, so its particles
    /// fly from one to the next.
    static let nnExplained: Story = {
        // Built when the story is first opened (`prepare`: about half a second and 180 MB), not at launch.
        let shared = LazyNetwork()
        var network: NeuralNetwork { shared.network }
        return Story(
            id: "nn-explained", title: "NN intro",
            steps: [
                nnStep("Black box", caption: "Cmd + fist to open the black box") {
                    [NetworkEffect(network, network.blackBox), BlackBoxEffect(network, network.blackBox)]
                },
                nnStep("Neural network", caption: "Pinch to move, two hands to zoom inside; hold space and point at a neuron") {
                    [NetworkEffect(network, network.brain)]
                },
                nnStep("Multilayer perceptron", caption: "Hold space and point at a neuron or a weight") {
                    [NetworkEffect(network, network.perceptron)]
                },
                nnStep("YOLO architecture", caption: "Backbone, neck, head: hold space and point at a block") {
                    [NetworkEffect(network, network.architecture)]
                },
                nnStep("Input and output", transition: .none, caption: "An image in, boxes and classes out") {
                    [NetworkEffect(network, network.inputOutput)]
                },
                nnStep("The input", transition: .none, caption: "The picture the model looks at") {
                    [NetworkEffect(network, network.picture)]
                },
                nnStep("Pixels", caption: "Zoomed in: a grid of pixels, each one color") {
                    [NetworkEffect(network, network.pixels)]
                },
                nnStep("RGB channels", caption: "Each pixel is three numbers: red, green and blue") {
                    [NetworkEffect(network, network.channels)]
                },
                nnStep("Grayscale", caption: "YOLO also takes grayscale images: a single channel") {
                    [NetworkEffect(network, network.grayscale)]
                },
                nnStep("Multispectral", caption: "…and multispectral images, e.g. 5 channels") {
                    [NetworkEffect(network, network.multispectral)]
                },
                nnStep("Back to the input", caption: "Back to the picture at the model's input") {
                    [NetworkEffect(network, network.pictureAgain)]
                },
                nnStep("Inference", transition: .none, loop: 8.5, caption: "The pixels flow through backbone, neck and head") {
                    [NetworkEffect(network, network.inference)]
                },
            ] + taskSteps(shared) + [
                nnStep("Conclusion", caption: "One image, one model, 7 tasks") {
                    [NetworkEffect(network, network.recap), RecapEffect(network, network.recap)]
                },
            ],
            prepare: { await shared.build() })
    }()

    /// The story's network, built by `build` (the story's `prepare`, which the app runs before the first step shows).
    private final class LazyNetwork {
        private var built: NeuralNetwork?
        var network: NeuralNetwork {
            guard let built else { preconditionFailure("NN intro: a step showed before the story was prepared") }
            return built
        }

        func build() async {
            if built == nil { built = await NeuralNetwork() }
        }
    }

    /// A step of the story: its effects, then the hand skeleton (every step tracks hands) and the step's caption.
    private static func nnStep(
        _ title: String, models: [String] = [], transition: Transition = .fade, loop: TimeInterval? = nil,
        showsCamera: Bool = false, caption: String, _ effects: @escaping () -> [Effect]
    ) -> Step {
        Step(title: title, models: models + ["mediapipe-hand"], transition: transition, loop: loop, showsCamera: showsCamera) {
            effects() + [handSkeleton(), titleCard(caption)]
        }
    }

    /// Each YOLO task's output: drawn on the cat picture, then live from YOLO26n on the camera.
    private static func taskSteps(_ shared: LazyNetwork) -> [Step] {
        let tasks: [(name: String, layout: KeyPath<TaskLayouts, NetworkLayout>, output: TaskOutputEffect.Output, caption: String, model: String, live: () -> [Effect])] = [
            ("Detect", \.detect, .box, "Detection: where each object is, what it is, how sure", "yolo26n", { [BoxesEffect(model: "yolo26n")] }),
            ("Segment", \.segment, .mask, "Segmentation: each object's exact pixels", "yolo26n-seg",
             { [OverlayEffect(model: "yolo26n-seg"), BoxesEffect(model: "yolo26n-seg")] }),
            ("Semantic", \.semantic, .semantic, "Semantic segmentation: a class for every pixel", "yolo26n-sem",
             { [OverlayEffect(model: "yolo26n-sem")] }),
            ("Classify", \.classify, .classes, "Classification: what the whole image is", "yolo26n-cls", { [ClassifyEffect(model: "yolo26n-cls")] }),
            ("Pose", \.pose, .keypoints, "Pose: keypoints of each object", "yolo26n-pose", { [PoseEffect(model: "yolo26n-pose"), BoxesEffect(model: "yolo26n-pose")] }),
            ("OBB", \.obb, .oriented, "Oriented boxes: rotated to fit tilted objects", "yolo26n-obb", { [OrientedBoxesEffect(model: "yolo26n-obb")] }),
            ("Depth", \.depth, .depth, "Depth: how far every pixel is", "yolo26n-depth", { [OverlayEffect(model: "yolo26n-depth", alpha: 0.7, depthColors: Palette.infernoGradient)] }),
        ]
        return tasks.flatMap { task in
            [
                nnStep(task.name, caption: task.caption) {
                    let network = shared.network, layout = network.tasks[keyPath: task.layout]
                    return [NetworkEffect(network, layout), TaskOutputEffect(network, layout, task.output)]
                },
            ] + (task.output != .semantic ? [] : [
                // Zoomed in: the class of each pixel, its ID on it.
                nnStep("Semantic · pixels", caption: "Every pixel gets a class: hold space and point at one") {
                    let network = shared.network, zoom = network.tasks.semanticZoom
                    return [NetworkEffect(network, zoom), TaskOutputEffect(network, zoom, .pixelClasses)]
                },
            ]) + [
                nnStep("\(task.name) · live", models: [task.model], showsCamera: true, caption: "Live: \(task.model) on the camera") {
                    task.live()
                },
            ]
        }
    }
}
