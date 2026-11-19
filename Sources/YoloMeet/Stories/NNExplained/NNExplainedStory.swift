import Foundation
import YoloMeetCore

extension Story {
    /// How a neural network works: a black box made of particles opens, and its particles become a brain, with the
    /// neurons and weights inside it, then some of them are laid out as a multilayer perceptron, then YOLO's
    /// architecture (backbone, neck, head) its input and output, the picture it looks at, its pixels, one pixel's
    /// three values, their red, green and blue channels, and the same picture in grayscale (one channel, then a client's
    /// grayscale picture beside it) or multispectral (five, then the ten layers of a client's wafer); then the picture
    /// flows through the model; a quiz on its seven tasks, each revealed opening its output (a branch of the quiz's
    /// step); a conclusion; and YOLO back in its black box, shipped: on GitHub, published to PyPI, installed with
    /// pip. The steps share one network, so its particles fly from one to the next.
    static let nnExplained: Story = {
        // Built when the story is first opened (`prepare`: about half a second and 180 MB), not at launch.
        let shared = LazyNetwork()
        var network: NeuralNetwork { shared.network }
        let center = CGPoint(x: 0.5, y: 0.5)
        return Story(
            id: "nn-explained", title: "CV onboarding",
            steps: [
                nnStep("Black box") {
                    [NetworkEffect(network, network.blackBox), BlackBoxEffect(network, network.blackBox)]
                },
                nnStep("Neural network") {
                    [NetworkEffect(network, network.brain)]
                },
                nnStep("Multilayer perceptron") {
                    [NetworkEffect(network, network.perceptron)]
                },
                nnStep("YOLO architecture") {
                    [NetworkEffect(network, network.architecture)]
                },
                nnStep("Input and output", transition: .none) {
                    [NetworkEffect(network, network.inputOutput)]
                },
                nnStep("The input", transition: .none) {
                    [NetworkEffect(network, network.picture)]
                },
                nnStep("Pixels") {
                    [NetworkEffect(network, network.pixels)]
                },
                nnStep("One pixel", transition: .none) {
                    [NetworkEffect(network, network.onePixel), PixelValuesEffect(network, network.onePixel)]
                },
                nnStep("RGB channels") {
                    [NetworkEffect(network, network.channels)]
                },
                // Each with a substep: a client's picture beside the cat's layers.
                nnStep(
                    "Grayscale",
                    substeps: [
                        // A client's grayscale picture: a golf club, 1280 × 1024, one channel.
                        nnStep("Golf club", transition: .none) {
                            [NetworkEffect(network, network.grayscaleExample)]
                        }
                    ]
                ) {
                    [NetworkEffect(network, network.grayscale)]
                },
                nnStep(
                    "Multispectral",
                    substeps: [
                        // A client's wafer: 10 layers, 10 channels; a defect goes through layers 4 to 7.
                        nnStep("Wafer", transition: .none) {
                            // It takes the stage's whole width: around its middle.
                            [NetworkEffect(network, network.multispectralExample, at: CGPoint(x: 0.5, y: 0.5))]
                        }
                    ]
                ) {
                    [NetworkEffect(network, network.multispectral)]
                },
                nnStep("Back to the input") {
                    [NetworkEffect(network, network.pictureAgain)]
                },
                nnStep("Inference", transition: .none, loop: 8.5) {
                    [NetworkEffect(network, network.inference)]
                },
                taskQuiz(shared),
                nnStep("Recap") {
                    [NetworkEffect(network, network.recap), RecapEffect(network, network.recap)]
                },
                // YOLO goes back into its black box, then out to the world: its code on GitHub, published to PyPI,
                // installed with pip.
                nnStep(
                    "GitHub",
                    substeps: [
                        nnStep("Repository") {
                            let shipping = network.shipping
                            return [
                                NetworkEffect(network, shipping.repository, at: center),
                                ShippingEffect(network, shipping, .repository),
                            ]
                        }
                    ]
                ) {
                    let packaged = network.shipping.packaged
                    return [NetworkEffect(network, packaged, at: center), BlackBoxEffect(network, packaged)]
                },
                nnStep(
                    "PyPI",
                    substeps: [
                        nnStep("pip install") {
                            [
                                NetworkEffect(network, network.shipping.install, at: center),
                                ShippingEffect(network, network.shipping, .install),
                            ]
                        }
                    ]
                ) {
                    [
                        NetworkEffect(network, network.shipping.pypi, at: center),
                        ShippingEffect(network, network.shipping, .pypi),
                    ]
                },
                nnStep("pip install ultralytics") {
                    [NetworkEffect(network, network.shipping.closing, at: center), ClosingEffect(network, network.shipping)]
                },
            ],
            prepare: { await shared.build() })
    }()

    /// The story's network, built by `build` (the story's `prepare`, which the app runs before the first step shows).
    private final class LazyNetwork {
        private var built: NeuralNetwork?
        var network: NeuralNetwork {
            guard let built else { preconditionFailure("CV onboarding: a step showed before the story was prepared") }
            return built
        }

        func build() async {
            if built == nil { built = await NeuralNetwork() }
        }
    }

    /// A step of the story: its effects, then the hand skeleton (every step tracks hands).
    private static func nnStep(
        _ title: String, models: [String] = [], transition: Transition = .fade, loop: TimeInterval? = nil,
        showsCamera: Bool = false, branches: [[Step]] = [], substeps: [Step] = [],
        _ effects: @escaping () -> [Effect]
    ) -> Step {
        Step(
            title: title, models: models + ["mediapipe-hand"], transition: transition, loop: loop,
            showsCamera: showsCamera, branches: branches, substeps: substeps
        ) {
            effects() + [handSkeleton()]
        }
    }

    /// The seven tasks as a quiz: the head's Detect blocks and their output arrow move to the left, the rest of the
    /// particles slide off to the left and come back from the right as a small swirling ball (`TaskQuiz`), and the
    /// tasks' names stand in a column between, blurred but for their first letter. Space + click one: it comes clear
    /// and its title flies to the top as the story enters its branch (its output on the cat, then live).
    private static func taskQuiz(_ shared: LazyNetwork) -> Step {
        let tasks = taskBranches(shared)
        return nnStep("Task quiz", branches: tasks.map(\.steps)) {
            let network = shared.network
            let output = TaskQuizEffect(network)  // first: it reads where the inference left the particles
            let items = zip(tasks, network.tasks.all).map { task, named in
                QuizEffect.Item(title: named.layout.title, subtitle: named.layout.subtitle, hint: task.hint)
            }
            // The titles fly over where the outputs will form: where the inference was.
            let quiz = QuizEffect(
                items, column: CGRect(x: 0.25, y: 0.14, width: 0, height: 0.74), titleX: { output.objectCenter($0).x })
            output.quiz = quiz
            // The quiz's motion after the layout forms (on the first frame), so it carries on from there.
            return [NetworkEffect(network, network.taskQuiz.layout, at: CGPoint(x: 0.5, y: 0.5)), output, quiz]
        }
    }

    /// Each YOLO task's output: drawn on the cat picture, then live from YOLO26n on the camera; with its name in
    /// Ultralytics and its pretraining dataset (`hint`, the quiz's clue, e.g. "detect · COCO"), in `TaskLayouts.all`'s
    /// order. The first step continues the quiz's title (no transition).
    private static func taskBranches(_ shared: LazyNetwork) -> [(hint: String, steps: [Step])] {
        let tasks:
            [(
                name: String, task: YOLOTask, layout: KeyPath<TaskLayouts, NetworkLayout>,
                output: TaskOutputEffect.Output, model: String, live: () -> [Effect]
            )] = [
                (
                    "Detect", .detect, \.detect, .box, "yolo26n", { [BoxesEffect(model: "yolo26n")] }
                ),
                (
                    "Segment", .segment, \.segment, .mask, "yolo26n-seg",
                    { [OverlayEffect(model: "yolo26n-seg"), BoxesEffect(model: "yolo26n-seg")] }
                ),
                (
                    "Semantic", .semantic, \.semantic, .semantic, "yolo26n-sem",
                    { [OverlayEffect(model: "yolo26n-sem")] }
                ),
                (
                    "Classify", .classify, \.classify, .classes, "yolo26n-cls",
                    { [ClassifyEffect(model: "yolo26n-cls")] }
                ),
                (
                    "Pose", .pose, \.pose, .keypoints, "yolo26n-pose",
                    { [PoseEffect(model: "yolo26n-pose"), BoxesEffect(model: "yolo26n-pose")] }
                ),
                (
                    "OBB", .obb, \.obb, .oriented, "yolo26n-obb",
                    { [OrientedBoxesEffect(model: "yolo26n-obb")] }
                ),
                (
                    "Depth", .depth, \.depth, .depth, "yolo26n-depth",
                    { [OverlayEffect(model: "yolo26n-depth", alpha: 0.7, depthColors: Palette.infernoGradient)] }
                ),
            ]
        // The quiz's clue under each name: the task in Ultralytics, and what its pretrained model learned from (depth's:
        // ARKitScenes, SUN RGB-D, DIODE, KITTI, Hypersim, TartanAir, Virtual KITTI 2 and ImageNet-1K, too long to list).
        let datasets: [YOLOTask: String] = [
            .detect: "COCO", .segment: "COCO", .semantic: "Cityscapes", .classify: "ImageNet",
            .pose: "COCO · 17 keypoints",
            .obb: "DOTA", .depth: "8 datasets",
        ]
        return tasks.map { task in
            (
                [task.task.rawValue, datasets[task.task]].compactMap { $0 }.joined(separator: " · "),
                [
                    nnStep(task.name, transition: .none) {
                        let network = shared.network
                        let layout = network.tasks[keyPath: task.layout]
                        return [NetworkEffect(network, layout), TaskOutputEffect(network, layout, task.output)]
                    }
                ]
                    + (task.output != .semantic
                        ? []
                        : [
                            // Zoomed in: the class of each pixel, its ID on it.
                            nnStep("Semantic · pixels") {
                                let network = shared.network
                                let zoom = network.tasks.semanticZoom
                                return [NetworkEffect(network, zoom), TaskOutputEffect(network, zoom, .pixelClasses)]
                            }
                        ]) + [
                        nnStep("\(task.name) · live", models: [task.model], showsCamera: true) {
                            task.live()
                        }
                    ]
            )
        }
    }
}
