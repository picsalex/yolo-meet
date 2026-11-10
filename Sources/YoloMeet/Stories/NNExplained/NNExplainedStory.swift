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
                Step(title: "Inference", models: ["mediapipe-hand"], transition: .none, loop: 7) {
                    [NetworkEffect(network, network.inference), handSkeleton(), titleCard("The pixels flow through backbone, neck and head")]
                },
            ])
    }()
}
