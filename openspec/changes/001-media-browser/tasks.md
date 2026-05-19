# Задачи

**Change:** 001-media-browser
**Total:** ~24h | **Services:** Multigram iOS app

---

### 1. Модуль MediaBrowserUI — scaffold `~2h`

- [ ] 1.1 Создать `submodules/TelegramUI/Components/Chat/MediaBrowserUI/BUILD` с зависимостями (Display, AsyncDisplayKit, TelegramCore, AccountContext, ChatTitleView) `~0.5h`
- [ ] 1.2 Создать `Sources/MediaBrowserController.swift` — пустой ViewController с init(context:peerId:) `~0.5h`
- [ ] 1.3 Создать `Sources/MediaBrowserDataSource.swift` — stub класс с peerId `~0.5h`
- [ ] 1.4 Добавить зависимость MediaBrowserUI в `submodules/TelegramUI/BUILD` `~0.5h`

**DoD:** `bazel build //submodules/TelegramUI/Components/Chat/MediaBrowserUI` зелёный

### 2. Кнопка в navigation bar чата `~4h`

- [ ] 2.1 Добавить action `.openMediaBrowser` в `ChatNavigationButtonAction` enum (`submodules/TelegramUI/Components/Chat/ChatNavigationButton/Sources/ChatNavigationButton.swift`) `~0.5h`
- [ ] 2.2 Создать `Sources/MediaBrowserButtonNode.swift` — круглая зелёная кнопка как ASDisplayNode (30pt, min tap area 44pt) `~1h`
- [ ] 2.3 В `ChatController.swift` (~строка 6055): создать mediaBrowserButton как UIBarButtonItem(customDisplayNode:), обернуть в ChatNavigationButton, добавить в rightBarButtonItems между title и avatar `~1.5h`
- [ ] 2.4 Условие видимости: показывать только если peer is `.user` (не group/channel) `~0.5h`
- [ ] 2.5 В `ChatControllerNavigationButtonAction.swift` (~строка 125): обработать `.openMediaBrowser` — вызов `present(MediaBrowserController(...), in: .window(.root))` с `.modalSheet` `~0.5h`

**DoD:** полный build зелёный; кнопка видна в 1-на-1 чате, скрыта в группе; тап открывает пустую модалку

### 3. Модальное окно — layout `~4h`

- [ ] 3.1 `MediaBrowserController.swift` — containerLayoutUpdated, displayNode setup, dismiss gesture (swipe down > 100pt) `~1.5h`
- [ ] 3.2 `Sources/MediaBrowserPlaceholderView.swift` — заглушка видеоплеера (тёмный прямоугольник, ~40% высоты экрана) `~0.5h`
- [ ] 3.3 `Sources/MediaBrowserTabBar.swift` — горизонтальный scroll view с табами ("На телике", "Закреп", "Все файлы" и др.), кнопка "назад" слева, активный таб подсвечен `~1.5h`
- [ ] 3.4 Интеграция placeholder + tabBar + list area в MediaBrowserController layout `~0.5h`

**DoD:** модалка открывается с анимацией, закрывается свайпом/кнопкой; placeholder и табы отображаются; layout адаптивен

### 4. Список медиафайлов — UI `~3h`

- [ ] 4.1 `Sources/MediaBrowserItemCell.swift` — ячейка: превью/иконка, имя файла, имя отправителя, время, размер `~1.5h`
- [ ] 4.2 `Sources/MediaBrowserListNode.swift` — ASCollectionNode/UICollectionView с вертикальным скроллом, регистрация ячейки, empty state ("Нет медиафайлов") `~1.5h`

**DoD:** список отображает mock-данные с правильным layout ячеек; пустое состояние видно при 0 элементах

### 5. Data source — загрузка медиа `~5h`

- [ ] 5.1 `MediaBrowserDataSource.swift` — метод `loadInitialBatch(filter:) -> Signal<[MediaItem], NoError>` через `TelegramEngine.Messages.searchMessages(peerId:, tags:, limit: 20)` `~1.5h`
- [ ] 5.2 Маппинг `EngineMessage` → `MediaItem` (fileName, senderName, timestamp, fileSize, mediaType, thumbnailResource) `~1h`
- [ ] 5.3 Пагинация: `loadNextBatch(after: EngineMessage.Id)` с offsetMessageId, состояние LoadingState (idle/loading/error/exhausted) `~1h`
- [ ] 5.4 Фильтрация по табам: маппинг TabFilter → MessageTags (.photo, .video, .file, .music); сброс списка и загрузка новой порции при смене таба `~1h`
- [ ] 5.5 Обработка ошибок: retry UI при network error, сохранение загруженных данных `~0.5h`

**DoD:** реальные медиафайлы чата загружаются и отображаются; пагинация работает при скролле; смена таба перезагружает список

### 6. Интеграция data source + UI `~3h`

- [ ] 6.1 Подключить MediaBrowserDataSource к MediaBrowserController: Signal subscription, обновление списка `~1h`
- [ ] 6.2 Подключить табы: при переключении таба — вызов dataSource.loadInitialBatch(filter:), сброс списка `~0.5h`
- [ ] 6.3 Бесконечная прокрутка: триггер loadNextBatch при 75% скролла `~0.5h`
- [ ] 6.4 Loading states: spinner при первой загрузке, footer spinner при подгрузке, ошибка + кнопка "Повторить" `~1h`

**DoD:** полный flow работает: кнопка → модалка → табы → список с lazy loading → dismiss

### 7. Polish и edge cases `~3h`

- [ ] 7.1 Тестирование на разных размерах экрана (SE, стандартный, Max) — проверить что кнопка не обрезается `~1h`
- [ ] 7.2 Dark/light theme: кнопка и модалка корректны в обеих темах `~0.5h`
- [ ] 7.3 Чат без медиа: кнопка видна, модалка показывает пустое состояние `~0.5h`
- [ ] 7.4 Исследовать API для табов "На телике" и "Закреп" — возможно нужны отдельные фильтры или пост-фильтрация `~1h`

**DoD:** все edge cases обработаны; UI корректен на всех размерах и темах

---

# План реализации

## Traceability

| Задачи | Requirement | Scenario |
|--------|-------------|---------|
| 2.2, 2.3, 2.4 | Отображение кнопки в 1-на-1 чате | Кнопка видна при открытии чата |
| 2.4 | Отображение кнопки в 1-на-1 чате | Кнопка скрыта в групповых чатах |
| 2.5 | Открытие медиабраузера по тапу | Тап открывает модалку |
| 2.3, 7.1 | Кнопка не мешает существующим элементам | Layout navigation bar сохраняется |
| 3.1 | Модальное окно поверх чата | Модалка открывается с анимацией |
| 3.1, 3.4 | Модальное окно поверх чата | Закрытие модалки |
| 3.2 | Заглушка видеоплеера | Отображение заглушки |
| 3.3 | Табы фильтрации медиа | Отображение табов |
| 6.2 | Табы фильтрации медиа | Переключение табов |
| 4.1 | Список медиафайлов | Отображение элемента списка |
| 4.2 | Список медиафайлов | Пустое состояние |
| 3.3 | Кнопка "назад" в табах | Нажатие кнопки назад |
| 5.1 | Первоначальная загрузка порции | Первая порция загружается |
| 6.4 | Первоначальная загрузка порции | Индикатор загрузки при первой порции |
| 6.3, 5.3 | Подгрузка следующей порции при скролле | Бесконечная прокрутка |
| 5.3 | Подгрузка следующей порции при скролле | Конец списка |
| 5.4 | Фильтрация по табам | Смена таба сбрасывает список |
| 5.5, 6.4 | Повтор при ошибке | Ошибка сети при подгрузке |
| 6.4 | Повтор при ошибке | Успешный повтор |

## Notes

- **Порядок реализации:** 1 → 2 → 3 → 4 → 5 → 6 → 7 (последовательный, каждый шаг строится на предыдущем)
- **Единственная точка изменения upstream:** ChatController.swift (~5 строк) + ChatNavigationButtonAction.swift (~10 строк). Весь остальной код в новом модуле MediaBrowserUI
- **Риск табов:** "На телике" и "Закреп" — нужно исследовать API на этапе 7.4. Возможно потребуется пост-фильтрация или отдельный запрос
- **Build:** каждый этап завершается полным `bazel build //Telegram:Telegram` с флагами `--//Telegram:disableExtensions=True --//Telegram:disableProvisioningProfiles=True`
