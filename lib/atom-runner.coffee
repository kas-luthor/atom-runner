{ConfigObserver} = require 'atom'

spawn = require('child_process').spawn
fs = require('fs')
url = require('url')
p = require('path')

AtomRunnerView = require './atom-runner-view'

class AtomRunner
  cfg:
    ext: 'runner.extensions'
    scope: 'runner.scopes'

  defaultExtensionMap:
    'spec.coffee': 'mocha'

  defaultScopeMap:
    coffee: 'coffee'
    js: 'node'
    ruby: 'ruby'
    python: 'python'
    go: 'go run'

  extensionMap: null
  scopeMap: null

  debug: (args...) ->
    console.debug('[atom-runner]', args...)

  initEnv: ->
    if process.platform == 'darwin'
      [shell, out] = [process.env.SHELL || 'bash', '']
      @debug('Importing ENV from', shell)
      pid = spawn(shell, ['--login', '-c', 'env'])
      pid.stdout.on 'data', (chunk) -> out += chunk
      pid.on 'error', =>
        @debug('Failed to import ENV from', shell)
      pid.on 'close', =>
        for line in out.split('\n')
          match = line.match(/^(\S+?)=(.+)/)
          process.env[match[1]] = match[2] if match
      pid.stdin.end()

  destroy: ->
    atom.config.unobserve @cfg.ext
    atom.config.unobserve @cfg.scope

  activate: ->
    @initEnv()
    @runnerView = null
    atom.config.setDefaults @cfg.ext, @defaultExtensionMap
    atom.config.setDefaults @cfg.scope, @defaultScopeMap
    atom.config.observe @cfg.ext, =>
      @extensionMap = atom.config.get(@cfg.ext)
    atom.config.observe @cfg.scope, =>
      @scopeMap = atom.config.get(@cfg.scope)
    atom.workspaceView.command 'atom-runner:run', => @run()
    atom.workspaceView.command 'atom-runner:stop', => @stop()

  run: ->
    editor = atom.workspace.getActiveEditor()
    return unless editor?

    path = editor.getPath()
    cmd = @commandFor(editor)
    unless cmd?
      console.warn("No registered executable for file '#{path}'")
      return

    previousPane = atom.workspaceView.getActivePaneView()
    if not @runnerView? or atom.workspaceView.find('.atom-runner').size() == 0
      @runnerView = new AtomRunnerView(editor.getTitle())
      panes = atom.workspaceView.getPaneViews()
      @pane = panes[panes.length - 1].splitRight(@runnerView)

    @runnerView.setTitle(editor.getTitle())
    if @pane and @pane.isOnDom()
      @pane.activateItem(@runnerView)
    @execute(cmd, editor)

  stop: ->
    if @child
      @child.kill()
      @child = null
      if @runnerView
        @runnerView.append('^C', 'stdin')

  runnerView: null
  pane: null

  execute: (cmd, editor) ->
    @stop()
    @runnerView.clear()

    args = []
    if editor.getPath()
      editor.save()
      args.push(editor.getPath())
    splitCmd = cmd.split(/\s+/)
    if splitCmd.length > 1
      cmd = splitCmd[0]
      args = splitCmd.slice(1).concat(args)
    try
      dir = atom.project.path || '.'
      if not fs.statSync(dir).isDirectory()
        dir = p.dirname(dir)
      @child = spawn(cmd, args, cwd: dir)
      @child.on 'error', (err) =>
        @runnerView.append(err.stack, 'stderr')
        @runnerView.scrollToBottom()
        @child = null
      @child.stderr.on 'data', (data) =>
        @runnerView.append(data, 'stderr')
        @runnerView.scrollToBottom()
      @child.stdout.on 'data', (data) =>
        @runnerView.append(data, 'stdout')
        @runnerView.scrollToBottom()
      @child.on 'close', (code, signal) =>
        @runnerView.footer('Exited with code=' + code + ' in ' +
          ((new Date - startTime) / 1000) + ' seconds')
        @child = null
    catch err
      @runnerView.append(err.stack, 'stderr')
      @runnerView.scrollToBottom()
      @stop()

    startTime = new Date
    unless editor.getPath()?
      @child.stdin.write(editor.getText())
    @child.stdin.end()
    @runnerView.footer('Running: ' + cmd + ' ' + editor.getPath())

  commandFor: (editor) ->
    # try to lookup by extension
    if editor.getPath()?
      for ext in Object.keys(@extensionMap).sort((a,b) -> b.length - a.length)
        if editor.getPath().match('\\.' + ext + '$')
          return @extensionMap[ext]

    # lookup by grammar
    scope = editor.getCursorScopes()[0]
    for name in Object.keys(@scopeMap)
      if scope.match('^source\\.' + name + '\\b')
        return @scopeMap[name]

module.exports = new AtomRunner
