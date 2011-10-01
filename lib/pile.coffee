fs = require "fs"
path = require "path"
crypto = require 'crypto'

_ = require "underscore"
async = require "async"

{minify, beautify} = require "./minify"
OB = require "./serialize"
compilers = require "./compilers"
assetUrlParse = require "./asseturlparse"


extension = (filename) ->
  parts = filename.split "."
  parts[parts.length-1]

wrapInScriptTagInline = (code) ->
  "<script type=\"text/javascript\" >\n#{ code }\n</script>\n"

getCompiler = (filePath) ->
  compiler = compilers[extension filePath]
  if not compiler
    throw new Error "Could not find compiler for #{ filePath }"
  compiler.render

#http://javascriptweblog.wordpress.com/2011/05/31/a-fresh-look-at-javascript-mixins/
asCodeOb = do ->
  getId = ->
    sum = crypto.createHash('sha1')
    if @type is "file"
      sum.update @filePath
    else
      sum.update OB.stringify @

    hash = sum.digest('hex').substring 10, 0

    if @type is "file"
      filename = _.last @filePath.split("/")
      filename = filename.replace ".", "_"
      hash = filename + "_" + hash

    return hash
  pilers =
    raw: (ob, cb) -> cb null, ob.raw
    object: (ob, cb) ->
      code = ""
      for k, v of ob.object
        code += "window['#{ k }'] = #{ OB.stringify v };\n"
      cb null, code
    exec: (ob, cb) ->
      cb null, executableFrom ob.object
    file: (ob, cb) ->
      fs.readFile ob.filePath, (err, data) =>
        return cb? err if err
        getCompiler(ob.filePath) data.toString(), (err, code) ->
          cb err, code

  return ->
    @getId = getId
    @getCode = (cb) ->
      pilers[@type] @, cb
    return @


class BasePile

  production: false

  constructor: (@name, @production) ->
    @code = []
    @rawPile = null
    @urls = []
    @devMapping = {}

  addFile: (filePath) ->
    if filePath not in @getFilePaths()
      @code.push asCodeOb.call
        type: "file"
        filePath: filePath


  addRaw: (raw) ->
    @code.push asCodeOb.call
      type: "raw"
      raw: raw

  getFilePaths: ->
    (ob.filePath for ob in @code when ob.type is "file")

  addUrl: (url) ->
    if url not in @urls
      @urls.push url



  renderTags: ->
    tags = ""
    for url in @urls
      tags += @wrapInTag url
      tags += "\n"


    if @production
      tags += @wrapInTag @getProductionUrl()
      tags += "\n"
    else
      for ob in @code
        tags += @wrapInTag "/pile/#{ @name }.dev-#{ ob.type }-#{ ob.getId() }.#{ @ext }", "id=\"pile-#{ ob.getId() }\""
        tags += "\n"

    tags


  findCodeObById: (id) ->
    (codeOb for codeOb in @code when codeOb.getId() is id)[0]

  findCodeObByFilePath: (path) ->
    (codeOb for codeOb in @code when codeOb.filePath is id)[0]


  getProductionUrl: ->
    "#{ @urlRoot }#{ @name }.min.#{ @ext }"

  getTagKey: ->
    if @production
      @pileHash
    else
      new Date().getTime()

  _computeHash: ->
    sum = crypto.createHash('sha1')
    sum.update @rawPile
    @pileHash = sum.digest('hex')

  convertToDevUrl: (path) ->
    "#{ @urlRoot }dev/#{ @name }/#{ @pathToId path }"

  pileUp: (cb) ->

    async.map @code, (codeOb, cb) =>
      codeOb.getCode (err, code) =>
        return cb? err if err
        cb null, @commentLine("#{ codeOb.type }: #{ codeOb.getId() }") + "\n#{ code }"

    , (err, result) =>
      return cb? err if err
      @rawPile = @minify result.join("\n\n").trim()
      @_computeHash()
      cb? null, @rawPile




class JSPile extends BasePile
  urlRoot: "/pile/js/"
  ext: "js"

  commentLine: (line) ->
    return "// #{ line.trim() }"

  minify: (code) ->
    if @production
      minify code
    else
      code

  constructor: ->
    super
    @objects = []
    @execs = []



  addOb: (ob) ->
    @code.push asCodeOb.call
      type: "object"
      object: ob


  addExec: (fn) ->
    @code.push asCodeOb.call
      type: "exec"
      object: fn


  wrapInTag: (uri, extra="") ->
    "<script type=\"text/javascript\"  src=\"#{ uri }?v=#{ @getTagKey() }\" #{ extra } ></script>"





class CSSPile extends BasePile
  urlRoot: "/pile/css/"
  ext: "css"

  commentLine: (line) ->
    return "/* #{ line.trim() } */"

  wrapInTag: (uri, extra="") ->
    "<link rel=\"stylesheet\" href=\"#{ uri }?v=#{ @getTagKey() }\" #{ extra } />"

  # TODO: Which lib to use?
  minify: (code) -> code


defNs = (fn) ->
  (ns, path) ->
    if arguments.length is 1
      path = ns
      ns = "_global"
    fn.call this, ns, path


class PileManager

  Type: null

  constructor: (@production) ->
    @piles =
      _global: new @Type "_global", @production

  getPile: (ns) ->
    pile = @piles[ns]
    if not pile
      pile =  @piles[ns] = new @Type ns, @production
    pile

  addFile: defNs (ns, path) ->
    pile = @getPile ns
    pile.addFile path

  addRaw: defNs (ns, raw) ->
    pile = @getPile ns
    pile.addRaw raw

  addUrl: defNs (ns, url) ->
    pile = @getPile ns
    pile.addUrl url

  pileUp: ->
    for name, pile of @piles
      pile.pileUp()

  renderTags: (namespaces...) ->
    # Always render global pile
    namespaces.unshift "_global"
    tags = ""
    for ns in namespaces
      pile = @piles[ns]
      if pile
        tags += pile.renderTags()
    tags

  bind: (app) ->

    @app = app

    app.on 'listening', =>
      @pileUp()
    @setDynamicHelper app


    @setMiddleware app

    pileUrl = /^\/pile\//

    # /pile/my.min.js
    # /pile/my.dev.js
    #
    #
    # /pile/js/dev/my-object-23432.js
    # /pile/js/dev/my-exec-23432.js
    #
    app.use (req, res, next) =>
      if not pileUrl.test req.url
        return next()

      res.setHeader "Content-type", @contentType
      asset = assetUrlParse req.url


      pile = @piles[asset.name]

      # Wrong asset type. Lets skip to next middleware.
      if asset.ext isnt pile.ext
        return next()

      if not pile
        res.send "Cannot find pile #{ pileName }"
        return

      if asset.min
        res.end pile.rawPile
        return

      if asset.dev
        codeOb = pile.findCodeObById asset.dev.uid
        codeOb.getCode (err, code) ->
          throw err if err
          res.end code
          return




class JSManager extends PileManager
  Type: JSPile
  contentType: "application/javascript"

  addOb: defNs (ns, ob) ->
    pile = @getPile ns
    pile.addOb ob

  addExec: defNs (ns, fn) ->
    pile = @getPile ns
    pile.addExec fn

  setDynamicHelper: (app) ->
    app.dynamicHelpers renderScriptTags: (req, res) => =>
      bundle = @renderTags.apply this, arguments
      if res._responseFns
        for fn in res._responseFns
          bundle += wrapInScriptTagInline executableFrom fn
      bundle

  setMiddleware: (app) ->
    responseExec = (fn) ->
      # "this" is the response object
      this._responseFns.push fn

    # Middleware that adds add & exec methods to response objects.
    app.use (req, res, next) ->
      res._responseFns ?= []
      res.exec = responseExec
      next()

class CSSManager extends PileManager
  Type: CSSPile
  contentType: "text/css"

  setDynamicHelper: (app) ->
    app.dynamicHelpers renderStyleTags: (req, res) =>
      return => @renderTags.apply this, arguments


  setMiddleware: (app) ->

# Creates immediately executable string presentation of given function.
# context will be function's "this" if given.
executableFrom = (fn, context) ->
  return "(#{ fn })();\n" unless context
  return "(#{ fn }).call(#{ context });\n"



LiveUpdateMixin = require "./livecss"
_.extend JSManager::, LiveUpdateMixin::

exports.production = production = process.env.NODE_ENV is "production"

exports.CSSPile = CSSPile
exports.JSPile = JSPile
exports.JSManager = JSManager
exports.CSSManager = CSSManager

exports.createJSManager = -> new JSManager production
exports.createCSSManager = -> new CSSManager production




