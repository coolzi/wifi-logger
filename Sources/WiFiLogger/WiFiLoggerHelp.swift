import AppKit
import SwiftUI

struct WiFiLoggerHelp: View {
    static let windowID = "wifi-logger-help"
    static let title: LocalizedStringKey = "Справка Wi-Fi Logger"

    private enum Topic: String, CaseIterable {
        case recording = "Запись"
        case timeline = "Навигация по графику"
        case signal = "Сигнал и обрывы"
        case modulation = "Модуляция и скорость"
        case export = "Сохранение CSV"
        case network = "Имя сети и BSSID"
        case accessPoints = "Имена точек доступа"

        var symbol: String {
            switch self {
            case .recording: "record.circle"
            case .timeline: "chart.xyaxis.line"
            case .signal: "wifi"
            case .modulation: "waveform.path"
            case .export: "doc"
            case .network: "location"
            case .accessPoints: "list.bullet.rectangle"
            }
        }
    }

    // Select the property wrappers when Command Line Tools do not include SwiftUIMacros.
    private typealias TopicState = State<Topic>
    private typealias ExpansionState = State<Bool>
    @TopicState private var selectedTopic = .recording
    @ExpansionState private var showsCSVReference = false
    @StateObject private var articleReference = WiFiViewReference()

    var body: some View {
        HStack(spacing: 0) {
            List(Topic.allCases, id: \.self, selection: topicSelection) { topic in
                Label {
                    Text(LocalizedStringKey(topic.rawValue), tableName: "Help")
                } icon: {
                    Image(systemName: topic.symbol)
                }
                .tag(topic)
            }
            .listStyle(.sidebar)
            .accessibilityLabel(Text("Разделы справки", tableName: "Help"))
            .frame(width: 212)

            Divider()

            ScrollView {
                selectedArticle
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
                    .background(WiFiViewAnchor(reference: articleReference).allowsHitTesting(false))
            }
            .id(selectedTopic)
            .focusable(interactions: .edit)
            .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown, .home, .end],
                        phases: [.down, .repeat], action: scrollArticle)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var topicSelection: Binding<Topic?> {
        Binding(get: { selectedTopic }, set: { topic in
            if let topic { selectedTopic = topic }
        })
    }

    private func scrollArticle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
              let scrollView = articleReference.view?.enclosingScrollView else { return .ignored }
        let clip = scrollView.contentView
        let down: CGFloat = clip.isFlipped ? 1 : -1
        var target = clip.bounds
        let line = scrollView.verticalLineScroll
        let page = max(0, target.height - max(line, scrollView.verticalPageScroll))
        let extent = clip.documentRect.height + target.height

        switch press.key {
        case .upArrow: target.origin.y -= down * line
        case .downArrow: target.origin.y += down * line
        case .pageUp: target.origin.y -= down * page
        case .pageDown: target.origin.y += down * page
        case .home: target.origin.y -= down * extent
        case .end: target.origin.y += down * extent
        default: return .ignored
        }

        // SwiftUI focuses the article but doesn't forward scroll keys to its AppKit scroll view.
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        scrollView.reflectScrolledClipView(clip)
        return .handled
    }

    @ViewBuilder private var selectedArticle: some View {
        switch selectedTopic {
        case .recording:
            article("Записать замеры") {
                paragraph("Нажмите **«Начать запись»** или **⌘R**. Приложение делает замер Wi-Fi примерно каждые 250 мс.")
                paragraph("""
                    **«Приостановить запись»** сохраняет накопленные замеры и снимки в окне. \
                    **«Продолжить запись»** добавляет данные к той же сессии.
                    """)
            }
        case .timeline:
            article("Найти момент на графике") {
                paragraph("""
                    В меню **«Диапазон»** выберите от 30 с до 15 мин. На вкладке **«Замеры Wi-Fi»** стрелки и ползунок \
                    **«Окно графика»** под графиком сдвигают видимый период. Они появляются, когда в записи несколько \
                    замеров и часть из них находится за пределами видимого диапазона.
                    """)
                paragraph("""
                    Чтобы выбрать момент, щёлкните по графику \
                    или по строке в **«Событиях»**. **«Выбранный момент»** вверху окна и диапазон сохраняются при смене вкладки. \
                    Если ближайший замер или снимок получен в другое время, оно указано рядом с его данными. \
                    **«К последним данным»** вернёт обе вкладки к концу записи.
                    """)
                subsection("С клавиатуры") {
                    paragraph("""
                        Для выбора с клавиатуры нажимайте **Tab**, пока фокус не окажется на графике. \
                        **←** и **→** перебирают замеры и снимки в видимом диапазоне. На графике NSS они переходят между доступными показаниями. \
                        **Enter** выбирает показанный замер, снимок или показание.
                        """)
                }
            }
        case .signal:
            article("Понять сигнал и обрывы") {
                paragraph("""
                    RSSI — уровень сигнала. Значение −55 дБм означает более сильный сигнал, чем −70 дБм. \
                    Чем выше SNR, тем лучше сигнал различим на фоне шума. В режимах **«Сигнал и шум»** и **SNR** \
                    пороги качества доступны под графиком в разделе **«Как читать цвета»**.
                    """)
                paragraph("""
                    В **«Событиях»** видны обрывы и восстановления связи, изменения номера, диапазона или ширины канала. \
                    Приложение отмечает смену точки доступа, когда у соседних замеров подключения совпадает SSID и меняется BSSID.
                    """)
            }
        case .modulation:
            article("Сравнить модуляцию и скорость") {
                paragraph("""
                    Откройте вкладку **«Снимки модуляции»** и выберите точку на графике MCS, скорости передачи или NSS. \
                    Снимки собираются отдельными запросами. macOS может сообщить MCS, режим Wi-Fi, канал и скорость передачи по соединению Wi-Fi.
                    """)
                paragraph("""
                    Для известных сочетаний MCS и режима Wi-Fi приложение показывает модуляцию и кодовую скорость. \
                    Для 1024-QAM один символ на поднесущей кодирует 10 бит в одном пространственном потоке. \
                    При тех же условиях больше бит на символ позволяют передавать данные быстрее. \
                    Цвет точки MCS показывает тип модуляции. Цвета можно сверить в **«Как читать цвета MCS»** под графиками. \
                    Полоса **«Запрос macOS»** показывает интервал от начала запроса до ответа.
                    """)
                paragraph("""
                    Когда накопится хотя бы два снимка, переключайтесь между ними стрелками или ползунком **«Выбор снимка»**. \
                    VoiceOver озвучивает у ползунка время ответа по снимку.
                    """)
                paragraph("""
                    **NSS (macOS)** — число пространственных потоков. Под числом указано время отдельного ответа macOS. \
                    Если число потоков недоступно или приложение обнаружило смену точки доступа, в карточке будет прочерк, а на графике — пропуск.
                    """)
            }
        case .export:
            article("Сохранить запись") {
                paragraph("""
                    В окне записи откройте **«Сохранить CSV»**. Пункты **«Замеры Wi-Fi…»** и **«Снимки модуляции…»** \
                    сохраняют данные в отдельные файлы. Экспорт работает во время записи. В файл попадут данные, \
                    накопленные к моменту подтверждения сохранения.
                    """)
                paragraph("""
                    Чтобы сохранить всю историю перед закрытием окна или сбросом через **«Новая запись…»**, \
                    приостановите запись и сохраните каждый доступный CSV. Пауза фиксирует конец записи для обоих файлов. \
                    Время последнего замера и последнего снимка может различаться.
                    """)
                csvReference
            }
        case .network:
            article("Показать имя сети и BSSID") {
                paragraph("""
                    При подключении к Wi-Fi имя сети и адрес точки доступа (BSSID) могут быть скрыты. \
                    На вкладке **«Замеры Wi-Fi»** нажмите **«Разрешить»**, если приложение предлагает доступ. После отказа откройте \
                    **«Системные настройки» → «Конфиденциальность и безопасность» → «Службы геолокации»** \
                    и разрешите доступ Wi-Fi Logger. Если запись на паузе, продолжите её, чтобы обновить поля.
                    """)
            }
        case .accessPoints:
            accessPointArticle
        }
    }

    private var accessPointArticle: some View {
        article("Загрузить имена точек доступа") {
            subsection("Подготовьте CSV") {
                paragraph("""
                    Сохраните файл в кодировке UTF-8. В первой строке укажите `bssid,ap_name`. \
                    Добавьте хотя бы одну запись. В каждой записи укажите BSSID (MAC-адрес точки доступа) и её непустое имя через запятую. \
                    Имя должно быть на одной строке, без табуляции и других управляющих символов.
                    """)
                Text(verbatim: String(localized: """
                    bssid,ap_name
                    02:11:22:33:44:55,Кабинет 301
                    0211-2233-4466,"Холл, зона ""А"" у входа"
                    """, table: "Help"))
                    .font(.callout.monospaced())
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                paragraph("""
                    BSSID можно записать с двоеточиями или в формате Huawei с дефисами. Регистр букв в адресе не важен. \
                    Одно имя можно указать для нескольких BSSID. Если один адрес встречается несколько раз, \
                    у него должно быть одно и то же имя.
                    """)
                paragraph("""
                    Если в имени есть запятая или двойная кавычка, заключите имя в двойные кавычки. \
                    Каждую двойную кавычку внутри имени запишите дважды.
                    """)
            }
            subsection("Загрузите справочник") {
                paragraph("""
                    Выберите **«Файл» → «Импорт имён точек доступа…»** и откройте CSV. \
                    Сверьте число уникальных имён и адресов BSSID. При первой загрузке нажмите **«Загрузить»**. \
                    Если приложение указало номер строки с ошибкой, исправьте её и откройте файл снова.
                    """)
                paragraph("""
                    При повторном импорте диалог покажет, сколько BSSID добавится, потеряет имя или сменит его. \
                    Кнопка **«Заменить»** применяет новый список целиком. Чтобы сохранить нужные имена, перенесите их в новый CSV вместе с BSSID.
                    """)
                paragraph("""
                    Имя из справочника видно под BSSID в замере и рядом с соответствующим адресом в событии смены точки. \
                    Справочник доступен после перезапуска.
                    """)
            }
        }
    }

    private var csvReference: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Button {
                showsCSVReference.toggle()
            } label: {
                Label {
                    Text("Колонки CSV замеров Wi-Fi", tableName: "Help")
                } icon: {
                    Image(systemName: showsCSVReference ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(interactions: .edit)
            .onKeyPress(.space) {
                showsCSVReference.toggle()
                return .handled
            }
            .accessibilityValue(showsCSVReference
                ? Text("Развёрнуто", tableName: "Help")
                : Text("Свёрнуто", tableName: "Help"))

            if showsCSVReference {
                csvReferenceColumns
            }
        }
    }

    private var csvReferenceColumns: some View {
        VStack(alignment: .leading, spacing: 18) {
            csvColumns("Поля замера", note: """
                В файле одна строка на замер. Если состояние отличается от `подключено`, \
                все поля от `ssid` до `tx_rate_mbps` пустые.
                """, [
                ("timestamp", "Календарное время замера в ISO 8601 с миллисекундами и смещением часового пояса. Всегда заполнено."),
                ("state", "Состояние Wi-Fi. Возможные значения — `подключено`, `нет подключения`, `Wi-Fi выключен`, `состояние неизвестно`. Всегда заполнено."),
                ("ssid", "Имя сети, текст. Пусто, если имя недоступно, например macOS скрыла его из-за настроек геолокации. Экспорт может добавить начальный апостроф для защиты от формул в таблицах."),
                ("bssid", "MAC-адрес точки доступа, текст. Пусто, если адрес недоступен, например macOS скрыла его из-за настроек геолокации."),
                ("rssi_dbm", "Уровень принятого сигнала (RSSI), дБм. Пусто, если macOS не дала показание или вернула 0."),
                ("noise_dbm", "Уровень шума, дБм. Пусто, если macOS не дала показание или вернула 0."),
                ("snr_db", "Отношение сигнала к шуму, дБ. Приложение вычитает уровень шума из уровня сигнала. Пусто, если нет одного из показаний."),
                ("band", "Частотный диапазон, текст с единицей ГГц. Пусто, если диапазон неизвестен."),
                ("channel", "Номер канала. Пусто, если macOS не сообщила положительный номер."),
                ("channel_width_mhz", "Ширина канала, МГц. Пусто, если ширина недоступна или приложение её не распознало."),
                ("phy_mode", "Режим Wi-Fi по стандарту 802.11, например `802.11ax`. Пусто, если режим недоступен или приложение его не распознало."),
                ("tx_rate_mbps", "Скорость передачи по радиосоединению Wi-Fi (PHY), Мбит/с. Пусто, если macOS не сообщила конечное положительное значение."),
            ])

            csvColumns("Смена канала", note: """
                Приложение сравнивает два соседних замера с подключением в одном сегменте. \
                Если номера каналов известны, событием считается смена номера, известного диапазона или известной ширины.
                """, [
                ("channel_changed", "Признак смены канала. `1` в строке события, `0` в остальных строках. Всегда заполнено."),
                ("previous_band", "Диапазон в предыдущем замере, текст с единицей ГГц. Пусто вне события или если прежний диапазон неизвестен."),
                ("previous_channel", "Номер канала в предыдущем замере. Пусто вне события."),
                ("previous_channel_width_mhz", "Ширина канала в предыдущем замере, МГц. Пусто вне события или если прежняя ширина неизвестна."),
            ])

            csvColumns("Сводка обрывов", note: """
                Итоги на момент сохранения повторяются в каждой строке. В длительность входит интервал после \
                замера без связи или с выключенным Wi-Fi, если следующий замер в том же сегменте и его состояние известно. \
                Если запись началась без связи, длительность может быть больше нуля при нулевом счётчике обрывов.
                """, [
                ("session_outage_count", "Число переходов из подключения в отсутствие связи или выключенный Wi-Fi внутри сегмента. Всегда заполнено, при отсутствии переходов — 0."),
                ("session_outage_total_seconds", "Суммарное наблюдаемое время без связи, с. Всегда заполнено, при отсутствии таких интервалов — 0."),
                ("session_outage_longest_seconds", "Самый длительный наблюдаемый период без связи, с. Всегда заполнено, при отсутствии таких интервалов — 0."),
            ])

            csvColumns("RSSI и SNR за последние 60 секунд", note: """
                Окно отсчитывается назад от последнего замера в файле по монотонному времени. \
                Обе границы входят в окно. Результаты повторяются в каждой строке.
                """, [
                ("rssi_min_60s_dbm", "Минимальный RSSI в окне, дБм. Пусто, если в окне нет ни одного RSSI."),
                ("rssi_max_60s_dbm", "Максимальный RSSI в окне, дБм. Пусто, если в окне нет ни одного RSSI."),
                ("rssi_spread_60s_db", "Разность между максимальным и минимальным RSSI в окне, дБ. Пусто, если показаний RSSI меньше двух."),
                ("snr_min_60s_db", "Минимальный SNR в окне, дБ. Пусто, если в окне нет ни одного SNR."),
                ("snr_max_60s_db", "Максимальный SNR в окне, дБ. Пусто, если в окне нет ни одного SNR."),
                ("snr_spread_60s_db", "Разность между максимальным и минимальным SNR в окне, дБ. Пусто, если показаний SNR меньше двух."),
            ])

            csvColumns("Сегмент, время и версия расчёта", [
                ("segment_id", "Номер непрерывного участка записи, начиная с 0. Новый участок начинается после продолжения записи или при интервале между замерами больше 2,5 с либо меньше или равном нулю. Всегда заполнено."),
                ("monotonic_seconds", "Время замера в секундах от общей точки отсчёта приложения. Идёт во время паузы и сна и не зависит от перевода системных часов. Всегда заполнено."),
                ("calculation_version", "Номер версии правил расчёта, сейчас `1`. Всегда заполнено."),
            ])
        }
    }

    private func csvColumns(_ title: LocalizedStringKey, note: LocalizedStringKey? = nil,
                            _ columns: [(name: String, description: LocalizedStringKey)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title, tableName: "Help")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let note {
                Text(note, tableName: "Help")
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(columns, id: \.name) { column in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: column.name)
                        .font(.body.monospaced().weight(.medium))
                    Text(column.description, tableName: "Help")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func article<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title, tableName: "Help")
                .font(.largeTitle.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func subsection<Content: View>(_ title: LocalizedStringKey,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title, tableName: "Help")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func paragraph(_ text: LocalizedStringKey) -> some View {
        Text(text, tableName: "Help")
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}
