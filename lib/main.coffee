fs = require 'fs-plus'
{CompositeDisposable} = require 'via'

MarkdownPreviewView = null
renderer = null

isMarkdownPreviewView = (object) ->
  MarkdownPreviewView ?= require './markdown-preview-view'
  object instanceof MarkdownPreviewView

module.exports =
  activate: ->
    @disposables = new CompositeDisposable()
    @commandSubscriptions = new CompositeDisposable()

    previewFile = @previewFile.bind(this)
    for extension in ['markdown', 'md', 'mdown', 'mkd', 'mkdown', 'ron', 'txt']
      @disposables.add via.commands.add ".tree-view .file .name[data-name$=\\.#{extension}]",
        'markdown-preview:preview-file', previewFile

    @disposables.add via.workspace.addOpener (uriToOpen) =>
      [protocol, path] = uriToOpen.split('://')
      return unless protocol is 'markdown-preview'

      try
        path = decodeURI(path)
      catch
        return

      if path.startsWith 'editor/'
        @createMarkdownPreviewView(editorId: path.substring(7))
      else
        @createMarkdownPreviewView(filePath: path)

  deactivate: ->
    @disposables.dispose()
    @commandSubscriptions.dispose()

  createMarkdownPreviewView: (state) ->
    if state.editorId or fs.isFileSync(state.filePath)
      MarkdownPreviewView ?= require './markdown-preview-view'
      new MarkdownPreviewView(state)

  toggle: ->
    if isMarkdownPreviewView(via.workspace.getActivePaneItem())
      via.workspace.destroyActivePaneItem()
      return

    editor = via.workspace.getActiveTextEditor()
    return unless editor?

    grammars = via.config.get('markdown-preview.grammars') ? []
    return unless editor.getGrammar().scopeName in grammars

    @addPreviewForEditor(editor) unless @removePreviewForEditor(editor)

  uriForEditor: (editor) ->
    "markdown-preview://editor/#{editor.id}"

  removePreviewForEditor: (editor) ->
    uri = @uriForEditor(editor)
    previewPane = via.workspace.paneForURI(uri)
    if previewPane?
      previewPane.destroyItem(previewPane.itemForURI(uri))
      true
    else
      false

  addPreviewForEditor: (editor) ->
    uri = @uriForEditor(editor)
    previousActivePane = via.workspace.getActivePane()
    options =
      searchAllPanes: true
    if via.config.get('markdown-preview.openPreviewInSplitPane')
      options.split = 'right'
    via.workspace.open(uri, options).then (markdownPreviewView) ->
      if isMarkdownPreviewView(markdownPreviewView)
        previousActivePane.activate()

  previewFile: ({target}) ->
    filePath = target.dataset.path
    return unless filePath

    for editor in via.workspace.getTextEditors() when editor.getPath() is filePath
      @addPreviewForEditor(editor)
      return

    via.workspace.open "markdown-preview://#{encodeURI(filePath)}", searchAllPanes: true

  copyHTML: ->
    editor = via.workspace.getActiveTextEditor()
    return unless editor?

    renderer ?= require './renderer'
    text = editor.getSelectedText() or editor.getText()
    renderer.toHTML text, editor.getPath(), editor.getGrammar(), (error, html) ->
      if error
        console.warn('Copying Markdown as HTML failed', error)
      else
        via.clipboard.write(html)

  saveAsHTML: ->
    activePane = via.workspace.getActivePaneItem()
    if isMarkdownPreviewView(activePane)
      activePane.saveAs()
      return

    editor = via.workspace.getActiveTextEditor()
    return unless editor?

    grammars = via.config.get('markdown-preview.grammars') ? []
    return unless editor.getGrammar().scopeName in grammars

    uri = @uriForEditor(editor)
    markdownPreviewPane = via.workspace.paneForURI(uri)
    return unless markdownPreviewPane?

    previousActivePane = via.workspace.getActivePane()
    markdownPreviewPane.activate()
    activePane = via.workspace.getActivePaneItem()

    if isMarkdownPreviewView(activePane)
      activePane.saveAs().then ->
        previousActivePane.activate()
