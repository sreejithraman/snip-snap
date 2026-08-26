import Foundation

struct SnipListIconCategory: Identifiable {
    let title: String
    let icons: [String]

    var id: String { title }
}

enum SnipListIconOptions {
    // TODO: Rename after the 1.0 migration window.
    // Keep the original key so upgrades retain recent icon choices.
    static let recentsDefaultsKey = "recentSectionIcons"

    static let categories = [
        SnipListIconCategory(title: "AI & Data", icons: [
            "brain.fill", "atom", "function", "sum",
            "chart.xyaxis.line", "chart.dots.scatter", "chart.bar.doc.horizontal.fill", "waveform.path.ecg",
            "tablecells.fill", "square.grid.3x3.fill", "circle.hexagongrid.fill", "point.3.filled.connected.trianglepath.dotted",
            "sparkle.magnifyingglass", "sparkle.text.clipboard.fill", "text.magnifyingglass", "doc.text.magnifyingglass",
            "magnifyingglass", "line.3.horizontal.decrease.circle.fill", "slider.horizontal.3", "chart.pie.fill"
        ]),
        SnipListIconCategory(title: "Developer Tools", icons: [
            "terminal.fill", "apple.terminal.fill", "hammer.fill", "wrench.and.screwdriver.fill",
            "gearshape.fill", "curlybraces", "chevron.left.forwardslash.chevron.right", "swift",
            "command", "square.stack.3d.up.fill", "cube.fill", "cube.transparent.fill",
            "shippingbox.and.arrow.backward.fill", "externaldrive.fill", "server.rack", "network",
            "point.3.connected.trianglepath.dotted", "memorychip.fill", "cpu.fill", "cable.connector"
        ]),
        SnipListIconCategory(title: "Cloud & Security", icons: [
            "cloud.fill", "cloud.bolt.fill", "antenna.radiowaves.left.and.right", "wifi",
            "personalhotspot", "bolt.horizontal.fill", "lock.fill", "key.fill",
            "shield.fill", "firewall.fill", "globe", "globe.americas.fill",
            "externaldrive.badge.icloud", "internaldrive.fill", "opticaldiscdrive.fill", "macpro.gen3.fill",
            "display", "rectangle.connected.to.line.below", "arrow.triangle.branch", "arrow.triangle.merge"
        ]),
        SnipListIconCategory(title: "Productivity & Work", icons: [
            "circle.grid.2x2.fill", "tray.fill", "archivebox.fill", "folder.fill",
            "folder.badge.plus", "bookmark.fill", "tag.fill", "pin.fill",
            "paperclip", "link", "list.bullet", "checkmark.circle.fill",
            "checkmark.square.fill", "calendar", "calendar.badge.clock", "clock.fill",
            "bell.fill", "timer", "clipboard.fill", "checklist.checked"
        ]),
        SnipListIconCategory(title: "Communication & Social", icons: [
            "person.fill", "person.2.fill", "person.3.fill", "person.crop.circle.fill",
            "person.crop.square.fill", "bubble.left.fill", "bubble.right.fill", "bubble.left.and.bubble.right.fill",
            "message.fill", "envelope.fill", "envelope.open.fill", "phone.fill",
            "phone.arrow.up.right.fill", "video.bubble.left.fill", "mic.fill", "megaphone",
            "at", "number", "text.bubble.fill", "ellipsis.bubble.fill"
        ]),
        SnipListIconCategory(title: "Commerce & Marketplaces", icons: [
            "cart.fill", "bag.fill", "basket.fill", "gift.fill",
            "storefront.fill", "storefront.circle.fill", "shippingbox.fill", "truck.box.fill",
            "barcode", "qrcode", "receipt.fill", "tag.slash.fill",
            "creditcard.fill", "percent", "building.2.fill", "building.fill",
            "building.columns.fill", "scale.3d", "app.gift.fill", "app.badge.fill"
        ]),
        SnipListIconCategory(title: "Finance & Business", icons: [
            "banknote.fill", "dollarsign.circle.fill", "wallet.bifold.fill", "centsign.circle.fill",
            "chart.bar.fill", "chart.line.uptrend.xyaxis", "chart.line.uptrend.xyaxis.circle.fill", "briefcase.fill",
            "case.fill", "person.2.badge.gearshape.fill", "calendar.badge.checkmark", "checklist",
            "list.bullet.clipboard.fill", "clock.badge.checkmark.fill", "exclamationmark.triangle.fill", "info.circle.fill",
            "questionmark.bubble.fill", "bell.badge.fill", "arrow.triangle.2.circlepath", "truck.box.badge.clock.fill"
        ]),
        SnipListIconCategory(title: "Media & Creator", icons: [
            "photo.fill", "photo.on.rectangle.angled", "camera.fill", "camera.macro",
            "video.fill", "film.fill", "play.rectangle.fill", "play.circle.fill",
            "music.note", "music.note.list", "music.quarternote.3", "headphones",
            "speaker.wave.2.fill", "radio.fill", "tv.fill", "gamecontroller.fill",
            "theatermasks.fill", "waveform", "scissors", "rectangle.stack.fill"
        ]),
        SnipListIconCategory(title: "Health & Fitness", icons: [
            "heart.fill", "cross.case.fill", "stethoscope", "pills.fill",
            "cross.vial.fill", "medical.thermometer.fill", "bandage.fill", "syringe.fill",
            "facemask.fill", "brain.head.profile", "lungs.fill", "figure.run",
            "figure.strengthtraining.traditional", "figure.yoga", "dumbbell.fill", "soccerball",
            "basketball.fill", "tennisball.fill", "water.waves", "moon.zzz.fill"
        ]),
        SnipListIconCategory(title: "Education & Knowledge", icons: [
            "doc.fill", "doc.text.fill", "doc.richtext.fill", "doc.on.doc.fill",
            "doc.badge.plus", "folder.badge.gearshape", "newspaper.fill", "note.text",
            "book.closed.fill", "books.vertical.fill", "text.book.closed.fill", "pencil",
            "pencil.line", "highlighter", "graduationcap.fill", "backpack.fill",
            "globe.desk.fill", "flask.fill", "character.cursor.ibeam", "paragraphsign"
        ]),
        SnipListIconCategory(title: "Travel & Mobility", icons: [
            "car.fill", "bus.fill", "tram.fill", "bicycle",
            "airplane", "ferry.fill", "map.fill", "location.fill",
            "mappin", "mappin.and.ellipse", "suitcase.fill", "tent.fill",
            "mountain.2.fill", "tree.fill", "signpost.right.fill", "fuelpump.fill",
            "figure.hiking", "compass.drawing", "bed.double.circle.fill", "globe.asia.australia.fill"
        ]),
        SnipListIconCategory(title: "Food & Delivery", icons: [
            "fork.knife", "fork.knife.circle.fill", "cup.and.saucer.fill", "cup.and.heat.waves.fill",
            "mug.fill", "wineglass.fill", "birthday.cake.fill", "takeoutbag.and.cup.and.straw.fill",
            "carrot.fill", "fish", "leaf.fill", "flame.fill",
            "waterbottle.fill", "popcorn.fill", "frying.pan.fill", "oven.fill",
            "bicycle.circle.fill", "location.circle.fill", "clock.arrow.circlepath", "bell.and.waves.left.and.right.fill"
        ]),
        SnipListIconCategory(title: "Home & IoT", icons: [
            "house.fill", "lightbulb.fill", "lamp.table.fill", "fan.fill",
            "shower.fill", "bed.double.fill", "chair.lounge.fill", "refrigerator.fill",
            "stove.fill", "washer.fill", "dryer.fill", "dishwasher.fill",
            "robotic.vacuum.fill", "door.garage.closed", "sensor.fill", "switch.programmable.fill",
            "poweroutlet.type.a.fill", "air.conditioner.horizontal.fill", "lock.open.fill", "key.card.fill"
        ]),
        SnipListIconCategory(title: "Design & Creative", icons: [
            "paintpalette.fill", "paintbrush.fill", "paintbrush.pointed.fill", "eyedropper",
            "crop", "ruler.fill", "pencil.and.ruler.fill", "swatchpalette.fill",
            "circle.lefthalf.filled", "square.on.circle", "circle.on.square", "rectangle.on.rectangle",
            "scribble.variable", "lasso", "viewfinder", "camera.viewfinder",
            "person.crop.rectangle.stack.fill", "quote.bubble.fill", "textformat", "wand.and.sparkles"
        ]),
        SnipListIconCategory(title: "Fun & Games", icons: [
            "lizard.fill", "fossil.shell.fill", "cat.fill", "dog.fill",
            "bird.fill", "fish.fill", "tortoise.fill", "hare.fill",
            "ladybug.fill", "ant.fill", "pawprint.fill", "dice.fill",
            "checkerboard.rectangle", "balloon.2.fill", "face.smiling", "rainbow",
            "arcade.stick.console.fill", "puzzlepiece.fill", "crown.fill", "party.popper.fill"
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
        "sparkle.magnifyingglass": "ai search discovery",
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
        "sensor.fill": "smart home iot device",
        "building.2.fill": "office city work",
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
        "graduationcap.fill": "education school edtech learning",
        "takeoutbag.and.cup.and.straw.fill": "food delivery restaurant",
        "paintpalette.fill": "design creative art"
    ]

    static func title(for icon: String) -> String {
        icon.replacingOccurrences(of: ".", with: " ").capitalized
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
