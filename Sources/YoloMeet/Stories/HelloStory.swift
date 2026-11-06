import YoloMeetCore

extension Story {
    /// Demo story: one model per step, then everything together.
    static let hello = Story(
        id: "hello", title: "Hello YOLO",
        steps: [
            Step(title: "Who's here?", models: ["yolo26n"]) {
                [
                    BoxesEffect(
                        model: "yolo26n", filter: { d, o in o.name(of: d.classIndex) == "person" },
                        label: { d, _ in "Guest #\(d.trackID ?? 0)" }),
                    TextEffect(.topLeft) { frame in
                        let people = frame.outputs["yolo26n"]?.detections.filter { $0.classIndex == 0 }.count ?? 0
                        return people == 1 ? "1 person" : "\(people) people"
                    },
                    titleCard("Who's here?"),
                ]
            },
            Step(title: "Magic hands", models: ["yolo26n-pose"]) {
                [PoseEffect(model: "yolo26n-pose"), SparkleHandsEffect(model: "yolo26n-pose"), titleCard("Magic hands")]
            },
            Step(title: "Depth vision", models: ["yolo26n-depth"]) {
                [OverlayEffect(model: "yolo26n-depth", alpha: 0.75), titleCard("Depth vision")]
            },
            Step(title: "All together", models: ["yolo26n-seg", "yolo26n-pose"]) {
                [
                    OverlayEffect(model: "yolo26n-seg"), SparkleHandsEffect(model: "yolo26n-pose"),
                    titleCard("All together"),
                ]
            },
        ])
}
