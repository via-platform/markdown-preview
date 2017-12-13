path = require 'path'

{Emitter, Disposable, CompositeDisposable, File} = require 'via'
_ = require 'underscore-plus'
fs = require 'fs-plus'

renderer = require './renderer'

module.exports =
class MarkdownPreviewView
  @deserialize: (params) ->
    new MarkdownPreviewView(params)

  constructor: ({@editorId, @filePath}) ->
    @element = document.createElement('div')
    @element.classList.add('markdown-preview')
    @element.tabIndex = -1
    @emitter = new Emitter
    @loaded = false
    @disposables = new CompositeDisposable
    @registerScrollCommands()
    if @editorId?
      @resolveEditor(@editorId)
    else if via.packages.hasActivatedInitialPackages()
      @subscribeToFilePath(@filePath)
    else
      @disposables.add via.packages.onDidActivateInitialPackages =>
        @subscribeToFilePath(@filePath)

  serialize: ->
    deserializer: 'MarkdownPreviewView'
    filePath: @getPath() ? @filePath
    editorId: @editorId

  copy: ->
    new MarkdownPreviewView({@editorId, filePath: @getPath() ? @filePath})

  destroy: ->
    @disposables.dispose()
    @element.remove()

  registerScrollCommands: ->
    @disposables.add(via.commands.add(@element, {
      'core:move-up': =>
        @element.scrollTop -= document.body.offsetHeight / 20
        return
      'core:move-down': =>
        @element.scrollTop += document.body.offsetHeight / 20
        return
      'core:page-up': =>
        @element.scrollTop -= @element.offsetHeight
        return
      'core:page-down': =>
        @element.scrollTop += @element.offsetHeight
        return
      'core:move-to-top': =>
        @element.scrollTop = 0
        return
      'core:move-to-bottom': =>
        @element.scrollTop = @element.scrollHeight
        return
    }))
    return

  onDidChangeTitle: (callback) ->
    @emitter.on 'did-change-title', callback

  onDidChangeModified: (callback) ->
    # No op to suppress deprecation warning
    new Disposable

  onDidChangeMarkdown: (callback) ->
    @emitter.on 'did-change-markdown', callback

  subscribeToFilePath: (filePath) ->
    @file = new File(filePath)
    @emitter.emit 'did-change-title'
    @disposables.add @file.onDidRename => @emitter.emit 'did-change-title'
    @handleEvents()
    @renderMarkdown()

  resolveEditor: (editorId) ->
    resolve = =>
      @editor = @editorForId(editorId)

      if @editor?
        @emitter.emit 'did-change-title'
        @disposables.add @editor.onDidDestroy => @subscribeToFilePath(@getPath())
        @handleEvents()
        @renderMarkdown()
      else
        @subscribeToFilePath(@filePath)

    if via.packages.hasActivatedInitialPackages()
      resolve()
    else
      @disposables.add via.packages.onDidActivateInitialPackages(resolve)

  editorForId: (editorId) ->
    for editor in via.workspace.getTextEditors()
      return editor if editor.id?.toString() is editorId.toString()
    null

  handleEvents: ->
    lazyRenderMarkdown = _.debounce((=> @renderMarkdown()), 250)
    @disposables.add via.grammars.onDidAddGrammar -> lazyRenderMarkdown()
    if typeof via.grammars.onDidRemoveGrammar is 'function'
      @disposables.add via.grammars.onDidRemoveGrammar -> lazyRenderMarkdown()
    else
      # TODO: Remove onDidUpdateGrammar hook once onDidRemoveGrammar is released
      @disposables.add via.grammars.onDidUpdateGrammar -> lazyRenderMarkdown()

    via.commands.add @element,
      'core:save-as': (event) =>
        event.stopPropagation()
        @saveAs()
      'core:copy': (event) =>
        event.stopPropagation()
        @copyToClipboard()
      'markdown-preview:select-all': =>
        @selectAll()
      'markdown-preview:zoom-in': =>
        zoomLevel = parseFloat(getComputedStyle(@element).zoom)
        @element.style.zoom = zoomLevel + 0.1
      'markdown-preview:zoom-out': =>
        zoomLevel = parseFloat(getComputedStyle(@element).zoom)
        @element.style.zoom = zoomLevel - 0.1
      'markdown-preview:reset-zoom': =>
        @element.style.zoom = 1
      'markdown-preview:toggle-break-on-single-newline': ->
        keyPath = 'markdown-preview.breakOnSingleNewline'
        via.config.set(keyPath, not via.config.get(keyPath))
      'markdown-preview:toggle-github-style': ->
        keyPath = 'markdown-preview.useGitHubStyle'
        via.config.set(keyPath, not via.config.get(keyPath))

    changeHandler = =>
      @renderMarkdown()

      pane = via.workspace.paneForItem(this)
      if pane? and pane isnt via.workspace.getActivePane()
        pane.activateItem(this)

    if @file?
      @disposables.add @file.onDidChange(changeHandler)
    else if @editor?
      @disposables.add @editor.getBuffer().onDidStopChanging ->
        changeHandler() if via.config.get 'markdown-preview.liveUpdate'
      @disposables.add @editor.onDidChangePath => @emitter.emit 'did-change-title'
      @disposables.add @editor.getBuffer().onDidSave ->
        changeHandler() unless via.config.get 'markdown-preview.liveUpdate'
      @disposables.add @editor.getBuffer().onDidReload ->
        changeHandler() unless via.config.get 'markdown-preview.liveUpdate'

    @disposables.add via.config.onDidChange 'markdown-preview.breakOnSingleNewline', changeHandler

    @disposables.add via.config.observe 'markdown-preview.useGitHubStyle', (useGitHubStyle) =>
      if useGitHubStyle
        @element.setAttribute('data-use-github-style', '')
      else
        @element.removeAttribute('data-use-github-style')

    document.onselectionchange = =>
      selection = window.getSelection()
      selectedNode = selection.baseNode
      if selectedNode is null or @element is selectedNode or @element.contains(selectedNode)
        if selection.isCollapsed
          @element.classList.remove('has-selection')
        else
          @element.classList.add('has-selection')

  renderMarkdown: ->
    @showLoading() unless @loaded
    @getMarkdownSource()
    .then (source) => @renderMarkdownText(source) if source?
    .catch (reason) => @showError({message: reason})

  getMarkdownSource: ->
    if @file?.getPath()
      @file.read().then (source) =>
        if source is null
          Promise.reject("#{@file.getBaseName()} could not be found")
        else
          Promise.resolve(source)
      .catch (reason) -> Promise.reject(reason)
    else if @editor?
      Promise.resolve(@editor.getText())
    else
      Promise.reject()

  getHTML: (callback) ->
    @getMarkdownSource().then (source) =>
      return unless source?

      renderer.toHTML source, @getPath(), @getGrammar(), callback

  renderMarkdownText: (text) ->
    scrollTop = @element.scrollTop
    renderer.toDOMFragment text, @getPath(), @getGrammar(), (error, domFragment) =>
      if error
        @showError(error)
      else
        @loading = false
        @loaded = true
        @element.textContent = ''
        @element.appendChild(domFragment)
        @emitter.emit 'did-change-markdown'
        @element.scrollTop = scrollTop

  getTitle: ->
    if @file? and @getPath()?
      "#{path.basename(@getPath())} Preview"
    else if @editor?
      "#{@editor.getTitle()} Preview"
    else
      "Markdown Preview"

  getIconName: ->
    "markdown"

  getURI: ->
    if @file?
      "markdown-preview://#{@getPath()}"
    else
      "markdown-preview://editor/#{@editorId}"

  getPath: ->
    if @file?
      @file.getPath()
    else if @editor?
      @editor.getPath()

  getGrammar: ->
    @editor?.getGrammar()

  getDocumentStyleSheets: -> # This function exists so we can stub it
    document.styleSheets

  getTextEditorStyles: ->
    textEditorStyles = document.createElement("via-styles")
    textEditorStyles.initialize(via.styles)
    textEditorStyles.setAttribute "context", "via-text-editor"
    document.body.appendChild textEditorStyles

    # Extract style elements content
    Array.prototype.slice.apply(textEditorStyles.childNodes).map (styleElement) ->
      styleElement.innerText

  getMarkdownPreviewCSS: ->
    markdownPreviewRules = []
    ruleRegExp = /\.markdown-preview/
    cssUrlRegExp = /url\(via:\/\/markdown-preview\/assets\/(.*)\)/

    for stylesheet in @getDocumentStyleSheets()
      if stylesheet.rules?
        for rule in stylesheet.rules
          # We only need `.markdown-review` css
          markdownPreviewRules.push(rule.cssText) if rule.selectorText?.match(ruleRegExp)?

    markdownPreviewRules
      .concat(@getTextEditorStyles())
      .join('\n')
      .replace(/via-text-editor/g, 'pre.editor-colors')
      .replace(/:host/g, '.host') # Remove shadow-dom :host selector causing problem on FF
      .replace cssUrlRegExp, (match, assetsName, offset, string) -> # base64 encode assets
        assetPath = path.join __dirname, '../assets', assetsName
        originalData = fs.readFileSync assetPath, 'binary'
        base64Data = new Buffer(originalData, 'binary').toString('base64')
        "url('data:image/jpeg;base64,#{base64Data}')"

  showError: (result) ->
    @element.textContent = ''
    h2 = document.createElement('h2')
    h2.textContent = 'Previewing Markdown Failed'
    @element.appendChild(h2)
    if failureMessage = result?.message
      h3 = document.createElement('h3')
      h3.textContent = failureMessage
      @element.appendChild(h3)

  showLoading: ->
    @loading = true
    @element.textContent = ''
    div = document.createElement('div')
    div.classList.add('markdown-spinner')
    div.textContent = 'Loading Markdown\u2026'
    @element.appendChild(div)

  selectAll: ->
    return if @loading

    selection = window.getSelection()
    selection.removeAllRanges()
    range = document.createRange()
    range.selectNodeContents(@element)
    selection.addRange(range)

  copyToClipboard: ->
    return if @loading

    selection = window.getSelection()
    selectedText = selection.toString()
    selectedNode = selection.baseNode

    # Use default copy event handler if there is selected text inside this view
    if selectedText and selectedNode? and (@element is selectedNode or @element.contains(selectedNode))
      via.clipboard.write(selectedText)
    else
      @getHTML (error, html) ->
        if error?
          via.notifications.addError('Copying Markdown as HTML failed', {dismissable: true, detail: error.message})
        else
          via.clipboard.write(html)

  saveAs: ->
    return if @loading

    filePath = @getPath()
    title = 'Markdown to HTML'
    if filePath
      title = path.parse(filePath).name
      filePath += '.html'
    else
      filePath = 'untitled.md.html'
      if projectPath = via.project.getPaths()[0]
        filePath = path.join(projectPath, filePath)

    if htmlFilePath = via.showSaveDialogSync(filePath)

      @getHTML (error, htmlBody) =>
        if error?
          via.notifications.addError('Saving Markdown as HTML failed', {dismissable: true, detail: error.message})
        else
          html = """
            <!DOCTYPE html>
            <html>
              <head>
                  <meta charset="utf-8" />
                  <title>#{title}</title>
                  <style>#{@getMarkdownPreviewCSS()}</style>
              </head>
              <body class='markdown-preview' data-use-github-style>#{htmlBody}</body>
            </html>""" + "\n" # Ensure trailing newline

          fs.writeFileSync(htmlFilePath, html)
          via.workspace.open(htmlFilePath)
