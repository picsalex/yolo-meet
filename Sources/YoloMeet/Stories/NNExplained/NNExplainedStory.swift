extension Story {
    /// How a neural network works: a cloud of particles becomes a brain, with the neurons and weights inside it, then
    /// some of them are laid out as a multilayer perceptron, then YOLO's architecture (backbone, neck, head) and its input and output. The steps share one network, so its particles fly from one to the next.
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
                Step(title: "Input and output", models: ["mediapipe-hand"]) {
                    [
                        NetworkEffect(network, network.inputOutput), handSkeleton(),
                        titleCard("An image in, boxes and classes out"),
                    ]
                },
            ])
    }()
}
