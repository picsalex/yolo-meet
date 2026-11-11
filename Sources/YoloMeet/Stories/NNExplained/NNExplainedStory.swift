import YoloMeetCore

extension Story {
    /// How a neural network works: a cloud of particles becomes a brain, with the neurons and weights inside it, then
    /// some of them are laid out as a multilayer perceptron, then YOLO's architecture (backbone, neck, head) its input and output, the picture it looks at, its pixels, their red, green and blue channels, and the same picture in grayscale (one channel) or multispectral (five). The steps share one network, so its particles fly from one to the next.
    static let nnExplained: Story = {
        let network = NeuralNetwork()
        return Story(
            id: "nn-explained", title: "NN explained",
            steps: [
                Step(title: "Cloud", models: ["mediapipe-hand"]) {
                    [NetworkEffect(network, nil), handSkeleton(), titleCard("Cmd + fist to gather the particles")]
                },
                Step(title: "Neural network", models: ["mediapipe-hand"]) {
                    [NetworkEffect(network, network.brain), handSkeleton(), titleCard("Pinch to move, two hands to zoom inside; hold space and point at a neuron")]
                },
                Step(title: "Multilayer perceptron", models: ["mediapipe-hand"]) {
                    [NetworkEffect(network, network.perceptron), handSkeleton(), titleCard("Hold space and point at a neuron or a weight")]
                },
                Step(title: "YOLO architecture", models: ["mediapipe-hand"]) {
                    [NetworkEffect(network, network.architecture), handSkeleton(), titleCard("Backbone, neck, head: hold space and point at a block")]
                },
                Step(title: "Input and output", models: ["mediapipe-hand"], transition: .none) {
                    [
                        NetworkEffect(network, network.inputOutput), handSkeleton(),
                        titleCard("An image in, boxes and classes out"),
                    ]
                },
                Step(title: "The input", models: ["mediapipe-hand"], transition: .none) {
                    [NetworkEffect(network, network.picture), handSkeleton(), titleCard("The picture the model looks at")]
                },
                Step(title: "Pixels", models: ["mediapipe-hand"]) {
                    [NetworkEffect(network, network.pixels), handSkeleton(), titleCard("Zoomed in: a grid of pixels, each one color")]
                },
                Step(title: "RGB channels", models: ["mediapipe-hand"]) {
                    [NetworkEffect(network, network.channels), handSkeleton(), titleCard("Each pixel is three numbers: red, green and blue")]
                },
                Step(title: "Grayscale", models: ["mediapipe-hand"]) {
                    [NetworkEffect(network, network.grayscale), handSkeleton(), titleCard("YOLO also takes grayscale images: a single channel")]
                },
                Step(title: "Multispectral", models: ["mediapipe-hand"]) {
                    [NetworkEffect(network, network.multispectral), handSkeleton(), titleCard("…and multispectral images, e.g. 5 channels")]
                },
                Step(title: "Back to the input", models: ["mediapipe-hand"]) {
                    [NetworkEffect(network, network.pictureAgain), handSkeleton(), titleCard("Back to the picture at the model's input")]
                },
                Step(title: "Inference", models: ["mediapipe-hand"], transition: .none, loop: 8.5) {
                    [NetworkEffect(network, network.inference), handSkeleton(), titleCard("The pixels flow through backbone, neck and head")]
                },
            ] + taskSteps(network) + [
                Step(title: "Conclusion", models: ["mediapipe-hand"]) {
                    [
                        NetworkEffect(network, network.recap), RecapEffect(network, network.recap), handSkeleton(),
                        titleCard("One image, one model, 7 tasks"),
                    ]
                },
            ])
    }()

    /// Each YOLO task's output: drawn on the cat picture, then live from YOLO26n on the camera.
    private static func taskSteps(_ network: NeuralNetwork) -> [Step] {
        let t = network.tasks
        let tasks: [(name: String, layout: NetworkLayout, output: TaskOutputEffect.Output, caption: String, model: String, live: () -> [Effect])] = [
            ("Detect", t.detect, .box, "Detection: where each object is, what it is, how sure", "yolo26n", { [BoxesEffect(model: "yolo26n")] }),
            ("Segment", t.segment, .mask, "Segmentation: each object's exact pixels", "yolo26n-seg",
             { [OverlayEffect(model: "yolo26n-seg"), BoxesEffect(model: "yolo26n-seg")] }),
            ("Semantic", t.semantic, .semantic, "Semantic segmentation: a class for every pixel", "yolo26n-sem",
             { [OverlayEffect(model: "yolo26n-sem")] }),
            ("Classify", t.classify, .classes, "Classification: what the whole image is", "yolo26n-cls", { [ClassifyEffect(model: "yolo26n-cls")] }),
            ("Pose", t.pose, .keypoints, "Pose: keypoints of each object", "yolo26n-pose", { [PoseEffect(model: "yolo26n-pose"), BoxesEffect(model: "yolo26n-pose")] }),
            ("OBB", t.obb, .oriented, "Oriented boxes: rotated to fit tilted objects", "yolo26n-obb", { [OrientedBoxesEffect(model: "yolo26n-obb")] }),
            ("Depth", t.depth, .depth, "Depth: how far every pixel is", "yolo26n-depth", { [OverlayEffect(model: "yolo26n-depth", alpha: 0.7, depthColors: Palette.infernoGradient)] }),
        ]
        return tasks.flatMap { task in
            [
                Step(title: task.name, models: ["mediapipe-hand"]) {
                    [NetworkEffect(network, task.layout), TaskOutputEffect(network, task.layout, task.output), handSkeleton(), titleCard(task.caption)]
                },
            ] + (task.output != .semantic ? [] : [
                // Zoomed in: the class of each pixel, its ID on it.
                Step(title: "Semantic · pixels", models: ["mediapipe-hand"]) {
                    [
                        NetworkEffect(network, t.semanticZoom), TaskOutputEffect(network, t.semanticZoom, .pixelClasses), handSkeleton(),
                        titleCard("Every pixel gets a class: hold space and point at one"),
                    ]
                },
            ]) + [
                Step(title: "\(task.name) · live", models: [task.model, "mediapipe-hand"], showsCamera: true) {
                    task.live() + [handSkeleton(), titleCard("Live: \(task.model) on the camera")]
                },
            ]
        }
    }
}
