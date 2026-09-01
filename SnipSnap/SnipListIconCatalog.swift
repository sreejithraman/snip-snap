import Foundation

struct SnipListIconCategory: Identifiable {
    let title: String
    let icons: [String]

    var id: String { title }
}

enum SnipListIconOptions {
    // Keep the original key so upgrades retain recent icon choices.
    static let recentsDefaultsKey = "recentSectionIcons"

    static let categories = [
        SnipListIconCategory(title: String(localized: "Smileys & Emotion"), icons: [
            "heart.fill", "star.fill", "sparkles", "flame.fill",
            "hand.thumbsup.fill", "hand.thumbsdown.fill", "hand.wave.fill", "hands.clap.fill",
            "hands.sparkles.fill", "face.smiling", "face.dashed", "eyes",
            "eye.fill", "mouth.fill", "zzz", "drop.fill",
            "bolt.heart.fill", "heart.slash.fill", "heart.text.clipboard.fill", "heart.circle.fill",
            "crown.fill", "trophy.fill",
            "medal.fill", "gift.fill", "balloon.2.fill", "party.popper.fill",
            "fireworks", "burst.fill", "aqi.medium", "c.circle.fill",
            "bubble.left.fill", "bubble.right.fill", "bubble.left.and.bubble.right.fill", "ellipsis.bubble.fill",
            "quote.bubble.fill", "text.bubble.fill", "exclamationmark.bubble.fill", "questionmark.bubble.fill",
            "checkmark.bubble.fill", "person.crop.circle.badge.checkmark", "person.crop.circle.badge.xmark", "hand.raised.fingers.spread.fill"
        ]),
        SnipListIconCategory(title: String(localized: "People & Body"), icons: [
            "person.fill", "person.2.fill", "person.3.fill", "person.crop.circle.fill",
            "person.badge.plus", "person.fill.checkmark", "person.fill.xmark", "person.fill.questionmark",
            "person.2.badge.plus", "person.2.badge.minus", "person.2.gobackward", "person.3.sequence.fill",
            "figure.stand", "figure.wave", "figure.walk", "figure.run",
            "figure.roll", "figure.hiking", "figure.climbing", "figure.yoga",
            "figure.strengthtraining.traditional", "figure.cooldown", "figure.mind.and.body", "figure.child",
            "figure.2.and.child.holdinghands", "figure.and.child.holdinghands", "accessibility", "accessibility.fill",
            "figure.roll.runningpace", "ear.fill", "ear.badge.waveform", "nose.fill",
            "brain.fill", "brain.head.profile.fill", "lungs.fill", "hand.raised.fill",
            "hand.point.up.left.fill", "hand.point.up.fill", "hand.point.down.fill", "hand.point.left.fill",
            "hand.point.right.fill", "hand.tap.fill", "hand.draw.fill", "hand.pinch.fill",
            "hands.and.sparkles.fill", "touchid", "figure.boxing", "hand.palm.facing.fill"
        ]),
        SnipListIconCategory(title: String(localized: "Animals & Nature"), icons: [
            "dog.fill", "cat.fill", "hare.fill", "tortoise.fill",
            "lizard.fill", "bird.fill", "fish.fill", "seal.fill",
            "ant.fill", "ladybug.fill", "pawprint.fill", "microbe.fill",
            "fossil.shell.fill", "camera.macro", "camera.macro.circle.fill", "leaf.fill",
            "leaf.circle.fill", "tree.fill", "tree.circle.fill", "camera.macro.circle",
            "mountain.2.fill", "water.waves", "snowflake", "sun.max.fill",
            "moon.fill", "cloud.fill", "cloud.rain.fill", "cloud.sun.fill",
            "cloud.moon.fill", "cloud.snow.fill", "cloud.bolt.rain.fill", "cloud.fog.fill",
            "cloud.drizzle.fill", "cloud.hail.fill", "cloud.bolt.fill", "wind",
            "tornado", "hurricane", "thermometer.sun.fill", "thermometer.snowflake",
            "humidity.fill", "rainbow", "bolt.fill", "sunrise.fill",
            "sunset.fill", "moon.stars.fill", "service.dog.fill", "rosette",
            "cloud.sun.rain.fill", "thermometer.medium"
        ]),
        SnipListIconCategory(title: String(localized: "Food & Drink"), icons: [
            "fork.knife", "fork.knife.circle.fill", "cup.and.saucer.fill", "cup.and.heat.waves.fill",
            "mug.fill", "wineglass.fill", "birthday.cake.fill", "takeoutbag.and.cup.and.straw.fill",
            "carrot.fill", "fish", "waterbottle.fill", "popcorn.fill",
            "frying.pan.fill", "oven.fill", "stove.fill", "refrigerator.fill",
            "takeoutbag.and.cup.and.straw", "waterbottle", "wineglass", "mug",
            "cup.and.saucer", "birthday.cake", "carrot", "popcorn",
            "fish.circle.fill", "leaf.circle", "flame", "drop", "spoon.serving"
        ]),
        SnipListIconCategory(title: String(localized: "Travel & Places"), icons: [
            "car.fill", "bus.fill", "tram.fill", "bicycle",
            "motorcycle.fill", "scooter", "skateboard.fill", "sailboat.fill",
            "airplane", "airplane.departure", "airplane.arrival", "ferry.fill",
            "cablecar.fill", "car.side.fill", "truck.box.fill", "fuelpump.fill",
            "parkingsign.circle.fill", "road.lanes", "light.beacon.max.fill", "octagon.fill",
            "map.fill", "location.fill",
            "mappin", "mappin.and.ellipse", "suitcase.fill", "tent.fill",
            "compass.drawing", "signpost.right.fill", "binoculars.fill", "backpack.fill",
            "globe.americas.fill", "globe.europe.africa.fill", "globe.asia.australia.fill", "map.circle.fill",
            "house.fill", "house.and.flag.fill", "building.fill", "building.columns.fill",
            "house.lodge.fill", "storefront.fill", "tent.2.fill", "beach.umbrella.fill",
            "lifepreserver.fill", "clock.fill", "alarm.fill", "stopwatch.fill",
            "timer", "hourglass", "calendar", "calendar.circle.fill",
            "calendar.badge.clock", "train.side.front.car", "truck.pickup.side.fill"
        ]),
        SnipListIconCategory(title: String(localized: "Activities"), icons: [
            "balloon.fill", "ticket.fill", "soccerball", "baseball.fill",
            "basketball.fill", "football.fill", "tennisball.fill", "volleyball.fill",
            "rugbyball.fill", "cricket.ball.fill", "hockey.puck.fill", "skis.fill",
            "snowboard.fill", "surfboard.fill", "dumbbell.fill", "figure.soccer",
            "figure.baseball", "figure.basketball", "figure.american.football", "figure.tennis",
            "figure.volleyball", "figure.rugby", "figure.cricket", "figure.hockey",
            "figure.skiing.downhill", "figure.snowboarding", "figure.surfing", "figure.pool.swim",
            "figure.outdoor.cycle", "figure.golf", "figure.fencing", "figure.dance",
            "figure.socialdance", "figure.gymnastics", "figure.wrestling", "figure.equestrian.sports",
            "figure.rower", "figure.waterpolo", "figure.handball", "figure.bowling",
            "figure.archery", "figure.skating", "figure.fishing", "figure.curling",
            "figure.lacrosse", "figure.table.tennis", "figure.badminton", "figure.martial.arts",
            "figure.softball", "figure.field.hockey", "l.joystick.fill",
            "suit.spade.fill", "suit.heart.fill", "suit.diamond.fill", "suit.club.fill",
            "american.football.fill", "gamecontroller.fill", "dice.fill", "puzzlepiece.fill",
            "theatermasks.fill", "paintpalette.fill", "paintbrush.fill", "photo.fill",
            "camera.fill", "video.fill", "film.fill", "play.rectangle.fill",
            "music.note", "music.note.list", "headphones", "speaker.wave.2.fill",
            "speaker.slash.fill", "radio.fill", "waveform", "mic.fill",
            "guitars.fill", "pianokeys", "music.quarternote.3"
        ]),
        SnipListIconCategory(title: String(localized: "Objects"), icons: [
            "tshirt.fill", "shoe.fill", "hat.cap.fill", "eyeglasses",
            "sunglasses.fill", "handbag.fill", "umbrella.fill", "watch.analog",
            "airtag.fill", "key.fill", "key.card.fill", "iphone",
            "ipad", "laptopcomputer", "desktopcomputer", "display",
            "applewatch", "earpods", "keyboard.fill", "computermouse.fill",
            "printer.fill", "faxmachine.fill", "tv.fill", "magnifyingglass",
            "battery.100percent", "powerplug.fill", "cable.connector", "lightbulb.fill",
            "trash.fill", "flashlight.on.fill", "bell.fill", "book.fill",
            "book.closed.fill", "books.vertical.fill", "newspaper.fill", "doc.fill",
            "doc.text.fill", "doc.richtext.fill", "doc.on.doc.fill", "scroll.fill",
            "bookmark.fill", "pencil", "briefcase.fill", "folder.fill",
            "clipboard.fill", "paperclip", "ruler.fill", "scissors",
            "cabinet.fill", "lock.fill", "lock.open.fill", "hammer.fill",
            "wrench.and.screwdriver.fill", "screwdriver.fill", "gearshape.fill", "link",
            "scope", "viewfinder", "syringe.fill", "pills.fill",
            "bandage.fill", "stethoscope", "cross.case.fill", "facemask.fill",
            "fire.extinguisher.fill", "lamp.table.fill", "sofa.fill", "chair.lounge.fill",
            "bed.double.fill", "toilet.fill", "shower.fill", "bathtub.fill",
            "washer.fill", "dryer.fill", "dishwasher.fill", "person.text.rectangle.fill",
            "graduationcap.fill", "coat.fill", "hat.widebrim.fill", "helmet.fill",
            "ring", "horn.fill", "bell.slash.fill", "battery.0percent",
            "door.left.hand.closed", "window.vertical.closed", "bubbles.and.sparkles.fill", "staroflife.fill"
        ]),
        SnipListIconCategory(title: String(localized: "Symbols"), icons: [
            "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill", "questionmark.circle.fill",
            "info.circle.fill", "plus.circle.fill", "minus.circle.fill", "multiply.circle.fill",
            "divide.circle.fill", "equal.circle.fill", "infinity.circle.fill", "percent",
            "number", "at", "asterisk", "arrow.up",
            "arrow.down", "arrow.left", "arrow.right", "arrow.up.left",
            "arrow.up.right", "arrow.down.left", "arrow.down.right", "arrow.left.arrow.right",
            "arrow.up.arrow.down", "arrow.clockwise", "arrow.counterclockwise", "shuffle",
            "repeat", "repeat.1", "play.fill", "pause.fill",
            "stop.fill", "record.circle.fill", "eject.fill", "forward.fill",
            "backward.fill", "forward.end.fill", "backward.end.fill", "speaker.wave.3.fill",
            "wifi", "antenna.radiowaves.left.and.right", "wheelchair", "cross.fill",
            "flag.fill", "circle.fill", "square.fill", "diamond.fill",
            "triangle.fill", "arrow.3.trianglepath", "peacesign", "sos.circle.fill", "r.circle.fill"
        ]),
        SnipListIconCategory(title: String(localized: "Work & Planning"), icons: [
            "circle.grid.2x2.fill", "tray.fill", "archivebox.fill", "folder.badge.plus",
            "tag.fill", "pin.fill", "checklist", "list.bullet",
            "paperplane.fill", "envelope.fill", "message.fill", "phone.fill",
            "chart.bar.fill", "chart.line.uptrend.xyaxis", "chart.pie.fill", "tablecells.fill",
            "banknote.fill", "creditcard.fill", "receipt.fill", "cart.fill",
            "bag.fill", "shippingbox.fill", "circle.dotted", "pause.circle.fill",
            "nosign", "arrow.triangle.2.circlepath", "checkmark.seal.fill", "road.lanes.curved.right",
            "signpost.right.and.left.fill", "flag.checkered", "calendar.badge.checkmark", "square.stack.3d.up.fill",
            "point.3.connected.trianglepath.dotted", "rectangle.3.group.fill", "square.grid.3x3.fill", "list.bullet.indent",
            "square.stack.fill", "app.badge.fill", "rectangle.badge.checkmark", "exclamationmark.arrow.triangle.2.circlepath"
        ]),
        SnipListIconCategory(title: String(localized: "Communication"), icons: [
            "envelope.open.fill", "phone.arrow.up.right.fill", "video.bubble.left.fill", "megaphone"
        ]),
        SnipListIconCategory(title: String(localized: "Developer & Data"), icons: [
            "terminal.fill", "apple.terminal.fill", "curlybraces", "chevron.left.forwardslash.chevron.right",
            "swift", "command", "memorychip.fill", "cpu.fill",
            "server.rack", "network", "externaldrive.fill", "atom",
            "function", "chart.dots.scatter", "cylinder.fill", "arrow.triangle.branch",
            "arrow.triangle.merge", "arrow.triangle.pull", "tablecells.badge.ellipsis", "chart.bar.xaxis.ascending",
            "chart.xyaxis.line", "sum", "externaldrive.connected.to.line.below", "gearshape.2.fill",
            "bolt.horizontal.fill"
        ]),
        SnipListIconCategory(title: String(localized: "Design & Making"), icons: [
            "paintbrush.pointed.fill", "eyedropper", "crop", "pencil.and.ruler.fill",
            "swatchpalette.fill", "circle.lefthalf.filled", "square.on.circle", "circle.on.square",
            "rectangle.on.rectangle", "scribble.variable", "lasso", "wand.and.sparkles",
            "macwindow", "sidebar.left", "uiwindow.split.2x1", "rectangle.split.3x1.fill",
            "switch.2", "slider.horizontal.3", "line.3.horizontal.decrease", "line.3.horizontal.decrease.circle.fill",
            "square.3.layers.3d", "point.3.filled.connected.trianglepath.dotted", "cursorarrow.click", "selection.pin.in.out",
            "textformat"
        ]),
        SnipListIconCategory(title: String(localized: "Money, Shopping & Security"), icons: [
            "dollarsign.circle.fill", "eurosign.circle.fill", "bitcoinsign.circle.fill", "wallet.bifold.fill",
            "basket.fill", "barcode", "qrcode", "scale.3d",
            "plus.forwardslash.minus", "shield.fill", "person.badge.key.fill", "key.viewfinder",
            "firewall.fill",
            "lock.shield.fill"
        ])
    ]

    static let searchKeywords: [String: String] = [
        "circle.grid.2x2.fill": "dashboard overview apps",
        "tray.fill": "inbox collect",
        "archivebox.fill": "archive storage",
        "folder.fill": "files project",
        "briefcase.fill": "job business office",
        "hammer.fill": "build make tool",
        "wrench.and.screwdriver.fill": "tools repair fix",
        "terminal.fill": "code developer command",
        "heart.fill": "love favorite health",
        "lightbulb.fill": "idea inspiration",
        "brain.fill": "ai artificial intelligence machine learning",
        "paperplane.fill": "rocket launch send",
        "circle.dotted": "pending backlog status",
        "pause.circle.fill": "paused on hold status",
        "nosign": "blocked prohibited status",
        "arrow.triangle.2.circlepath": "sync refresh cycle automation",
        "checkmark.seal.fill": "approved verified complete",
        "road.lanes.curved.right": "roadmap path plan",
        "signpost.right.and.left.fill": "roadmap direction decision",
        "flag.checkered": "finish milestone goal",
        "arrow.triangle.branch": "branch fork code git",
        "arrow.triangle.merge": "merge code git",
        "arrow.triangle.pull": "pull request code git",
        "point.3.connected.trianglepath.dotted": "hierarchy graph dependency",
        "rectangle.3.group.fill": "group structure collection",
        "macwindow": "app product window",
        "sidebar.left": "sidebar navigation product ui",
        "slider.horizontal.3": "controls settings adjust",
        "line.3.horizontal.decrease.circle.fill": "filter refine",
        "square.3.layers.3d": "layers stack design",
        "cursorarrow.click": "click interaction cursor",
        "tablecells.badge.ellipsis": "data table database",
        "gearshape.2.fill": "automation process workflow",
        "firewall.fill": "security network protection",
        "person.badge.key.fill": "access account permission",
        "flag.fill": "flag milestone goal",
        "star.fill": "star favorite starred",
        "cylinder.fill": "database storage",
        "ladybug.fill": "bug issue defect",
        "hand.wave.fill": "wave hello goodbye",
        "hands.clap.fill": "clap applause celebrate",
        "hands.sparkles.fill": "thanks gratitude prayer",
        "trophy.fill": "winner award success",
        "medal.fill": "award rank achievement",
        "road.lanes": "traffic road route routing",
        "plus.forwardslash.minus": "calculator math accounting",
        "house.lodge.fill": "factory office place lodge",
        "leaf.circle.fill": "food fresh vegetarian",
        "chart.dots.scatter": "analytics data metrics",
        "cloud.fill": "cloud hosting saas",
        "shield.fill": "security privacy protection",
        "checkmark.circle.fill": "task todo done complete",
        "list.bullet": "tasks todo checklist",
        "bell.fill": "alert reminder notification",
        "person.2.fill": "team group people",
        "bubble.left.fill": "chat message comment",
        "bubble.left.and.bubble.right.fill": "chat messages conversation comments",
        "envelope.fill": "email mail",
        "phone.fill": "call contact",
        "video.fill": "meeting call camera",
        "photo.fill": "image picture",
        "music.note": "audio song",
        "mic.fill": "audio voice record",
        "film.fill": "movie video",
        "house.fill": "home place",
        "building.fill": "office city work",
        "airplane": "flight trip travel",
        "map.fill": "travel directions",
        "location.fill": "place pin travel",
        "suitcase.fill": "trip luggage travel",
        "cart.fill": "shop shopping purchase",
        "storefront.fill": "commerce ecommerce marketplace retail",
        "creditcard.fill": "money payment finance",
        "banknote.fill": "money cash finance",
        "bag.fill": "shop shopping purchase",
        "fork.knife": "food restaurant meal",
        "lizard.fill": "dinosaur dino reptile fun",
        "fossil.shell.fill": "dinosaur fossil prehistoric",
        "party.popper.fill": "celebrate party launch fun",
        "externaldrive.fill": "disk storage backup",
        "server.rack": "hosting database technology",
        "gearshape.fill": "settings preferences configure",
        "sun.max.fill": "weather day nature",
        "moon.fill": "night sleep nature",
        "pawprint.fill": "pet animal nature",
        "takeoutbag.and.cup.and.straw.fill": "food delivery restaurant",
        "paintpalette.fill": "design creative art",
        "graduationcap.fill": "education school edtech learning"
    ]

    static func title(for icon: String) -> String {
        let defaultTitle = icon.replacingOccurrences(of: ".", with: " ").capitalized
        return Bundle.main.localizedString(
            forKey: "icon.\(icon)",
            value: defaultTitle,
            table: nil
        )
    }

    static func matches(_ icon: String, query: String) -> Bool {
        "\(title(for: icon)) \(searchKeywords[icon] ?? "")"
            .localizedCaseInsensitiveContains(query)
    }

    static func recentIcons() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentsDefaultsKey) ?? []
    }

    static func recordRecentIcon(_ icon: String) {
        let icons = [icon] + recentIcons().filter { $0 != icon }
        UserDefaults.standard.set(Array(icons.prefix(8)), forKey: recentsDefaultsKey)
    }
}
