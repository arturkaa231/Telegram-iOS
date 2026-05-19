# Design: Media Browser Button

**Change ID:** 001-media-browser
**Date:** 2026-05-13

## Scope

Один модуль iOS-приложения. Межсервисного взаимодействия нет. Backend API не меняется — используем существующий Telegram shared media API через TelegramEngine.

---

## Architecture

### Карта компонентов

| Компонент | Роль | Runtime |
|-----------|------|---------|
| MediaBrowserButton | Кнопка в navigation bar чата | Swift/UIKit |
| MediaBrowserController | Модальный контроллер с табами и списком | Swift/UIKit |
| MediaBrowserDataSource | Загрузка и пагинация медиа через TelegramEngine | Swift |

### Интеграция в ChatController

**Точка входа:** `ChatController.swift` (~строка 6055), где создаются `chatInfoNavigationButton` и `moreInfoNavigationButton`.

**Паттерн:**
1. Кнопка создаётся как `UIBarButtonItem(customDisplayNode:)` — аналогично `ChatAvatarNavigationNode`
2. Оборачивается в `ChatNavigationButton` с новым action `.openMediaBrowser`
3. Добавляется в `ChatNavigationButtonAction` enum
4. Обработка тапа — в `ChatControllerNavigationButtonAction.swift` (~строка 125)
5. Показ модалки: `self.present(controller, in: .window(.root))` с `.modalSheet` анимацией

**Условие видимости:** кнопка отображается только если `peerId` является user (не group/channel). Проверяется через `EnginePeer` — `case .user`.

### Модальное окно

Стандартный `ViewController` из Display framework (не UIKit UIViewController напрямую). Содержит:
- **Верхняя часть:** view-заглушка (серый/тёмный прямоугольник, ~40% высоты)
- **Табы:** горизонтальный scroll view с кнопками фильтров
- **Список:** ASCollectionNode или UICollectionView с вертикальным скроллом

Dismiss: жест свайпа вниз + кнопка "назад" на панели табов.

### Data Flow

```
ChatController (peerId)
  → MediaBrowserController (peerId, accountContext)
    → MediaBrowserDataSource
      → TelegramEngine.Messages.searchMessages(peerId, tags, limit: 20, offset)
      → Signal<[EngineMessage], NoError>
    → UI обновляется через Signal subscription
```

---

## Decisions

### ADR-001: Новый модуль vs встраивание в ChatController

**Context:** MediaBrowser — новый UI. Можно добавить код прямо в ChatController или создать отдельный модуль.

**Choice:** Отдельный модуль `MediaBrowserUI` в `submodules/TelegramUI/Components/Chat/MediaBrowserUI/`

**Rationale:** ChatController.swift уже 6000+ строк. Отдельный модуль изолирует код, упрощает итерации и не загрязняет upstream.

**Alternatives:**
- Встроить в ChatController — отвергнуто: конфликты при обновлении upstream
- Отдельный submodule вне TelegramUI — отвергнуто: зависит от UI-компонентов TelegramUI

**Consequences:**
- (+) Чистое разделение от upstream кода
- (+) Можно разрабатывать и тестировать изолированно
- (-) Нужен BUILD-файл и зависимости

### ADR-002: Загрузка медиа через searchMessages vs peerSharedMediaData

**Context:** Telegram имеет несколько API для получения медиа чата.

**Choice:** `TelegramEngine.Messages.searchMessages` с `MessageTags` фильтрами.

**Rationale:** searchMessages поддерживает offset-пагинацию и фильтрацию по типу медиа. Уже используется в PeerInfo shared media. Понятный контракт.

**Alternatives:**
- `peerSharedMediaData` — отвергнуто: более сложный API, завязан на PostboxView

**Consequences:**
- (+) Простой сигнал-based API
- (+) Нативная поддержка пагинации через offsetMessageId
- (-) Нет real-time обновлений (но для v1 не нужно)

### ADR-003: Presentation style — modal sheet

**Context:** Как показать медиабраузер поверх чата.

**Choice:** `present(in: .window(.root))` с `ViewControllerPresentationArguments(presentationAnimation: .modalSheet)`

**Rationale:** Стандартный паттерн Telegram iOS для модальных экранов. Чат остаётся виден, поддерживается swipe-to-dismiss.

---

## NFR

| NFR | Target | Measurement |
|-----|--------|-------------|
| Tap-to-modal P99 | < 200ms | Время от тапа до первого фрейма модалки |
| First batch load P99 | < 1000ms | Время загрузки первых 20 элементов |
| Memory overhead | < 50MB | При 100 файлах в списке |
| Минимальная tap area | 44x44pt | Apple HIG |

## Риски

| Риск | Вероятность × Импакт | Митигация |
|------|---------------------|-----------|
| Navigation bar переполнен на маленьких экранах (SE) | Средняя × Средний | Тестировать на минимальном экране; кнопка 30pt, adaptive layout |
| ChatController upstream update ломает интеграцию | Высокая × Средний | Минимальная точка интеграции (~5 строк в ChatController); основной код в отдельном модуле |
| searchMessages API не возвращает нужные поля для табов ("На телике", "Закреп") | Средняя × Высокий | Исследовать API на этапе tasks; "На телике" может потребовать отдельный фильтр или пост-фильтрацию |

## Структура модуля

```
submodules/TelegramUI/Components/Chat/MediaBrowserUI/
├── BUILD
└── Sources/
    ├── MediaBrowserController.swift      — модальный контроллер
    ├── MediaBrowserDataSource.swift       — загрузка и пагинация
    ├── MediaBrowserTabBar.swift           — горизонтальные табы
    ├── MediaBrowserListNode.swift         — список файлов
    ├── MediaBrowserItemCell.swift         — ячейка списка
    └── MediaBrowserPlaceholderView.swift  — заглушка видеоплеера
```
