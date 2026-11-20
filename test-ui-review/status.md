# Simulator build: passed

- Branch: `test/ui-review`
- Commit: `957b0391829ffba4e4289287d8eb40fdedaeca82`
- Build type: full (lite = without the RAR/7z libraries)
- Errors: 0   Warnings: 8

## Warnings
```
2026-11-20 17:11:37.981 appintentsmetadataprocessor[3629:14038] warning: Metadata extraction skipped. No AppIntents.framework dependency found.
PanelSnap/Services/BrowserModel.swift:448:22: warning: consider using asynchronous alternative function
PanelSnap/Services/LibraryStore.swift:132:38: warning: instance method 'makeIterator' is unavailable from asynchronous contexts; this is an error in the Swift 6 language mode
PanelSnap/Services/ReaderModel.swift:123:38: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
PanelSnap/Services/ReaderModel.swift:139:34: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
PanelSnap/Services/ReaderModel.swift:186:47: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
PanelSnap/Services/ReaderModel.swift:197:38: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
PanelSnap/Services/ReaderModel.swift:61:13: warning: capture of 'cache' with non-Sendable type 'PanelCache' in a '@Sendable' closure
```
