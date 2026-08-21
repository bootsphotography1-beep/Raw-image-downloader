files = ['RawDeck/PhotoStore.swift', 'RawDeck/Services/ExternalAppService.swift', 'RawDeck/Services/ConvertService.swift', 'RawDeck/Views/ThumbnailCell.swift', 'RawDeck/RawDeckApp.swift', 'RawDeck/Views/ContentView.swift', 'RawDeck/Views/ToolbarView.swift']
for path in files:
    with open(path) as f:
        content = f.read()
    scrubbed = []
    i = 0
    while i < len(content):
        c = content[i]
        if i + 1 < len(content) and content[i:i+2] == '//':
            nl = content.find('\n', i)
            if nl == -1:
                break
            i = nl + 1
            continue
        if i + 1 < len(content) and content[i:i+2] == '/*':
            end = content.find('*/', i)
            if end == -1:
                break
            i = end + 2
            continue
        if c == '"':
            j = i + 1
            while j < len(content):
                if content[j] == '\\' and j + 1 < len(content):
                    j += 2
                    continue
                if content[j] == '"':
                    break
                j += 1
            i = j + 1
            continue
        scrubbed.append(c)
        i += 1
    text = ''.join(scrubbed)
    print(f'{path}:')
    print(f'  open  = {text.count("{")}')
    print(f'  close = {text.count("}")}')
    print(f'  paren open  = {text.count("(")}')
    print(f'  paren close = {text.count(")")}')
    print(f'  bracket open  = {text.count("[")}')
    print(f'  bracket close = {text.count("]")}')
