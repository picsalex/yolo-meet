extension Story {
    /// How a neural network works, from a brain made of particles to the neurons and weights inside it.
    static let nnExplained = Story(
        id: "nn-explained", title: "NN explained",
        steps: [
            Step(title: "Neural network", models: ["mediapipe-hand"]) {
                [BrainEffect(), handSkeleton(), titleCard("Space + fist on the particles, open to form a brain; pinch to move, two hands to zoom inside; hold space and point at a neuron")]
            },
        ])
}
