nconf = require("nconf")
request = require("request")
mime = require("mime")
express = require("express")
url = require("url")
revalidator = require("revalidator")
_ = require("underscore")._

apiErrors = require("./errors")

module.exports = app = express.createServer()

genid = (len = 16, prefix = "", keyspace = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") ->
  prefix += keyspace.charAt(Math.floor(Math.random() * keyspace.length)) while len-- > 0
  prefix


Database = require("./stores/memory").Database

users = new Database(filename: "/tmp/users.json")
auths = new Database(filename: "/tmp/auths.json")
plunks = new Database
  filename: "/tmp/plunks.json"
  comparator: (item) -> Date.parse(item.updated_at or item.created_at)



app.configure ->
  app.use require("./middleware/cors").middleware()
  app.use express.cookieParser()
  app.use require("./middleware/json").middleware()
  app.use require("./middleware/auth").middleware(auths: auths)
  app.use require("./middleware/user").middleware(users: users)
  app.use require("./middleware/tokens").middleware
    domain: url.parse(nconf.get("url:api")).host
    path: if nconf.get("nosubdomains") then app.route else "/"
    
  app.use app.router
  app.use (err, req, res, next) ->
    console.log err
    json = if err.toJSON? then err.toJSON() else
      message: err.message or "Unknown error"
      code: err.code or 500
    
    
    res.json(json, json.code)
    
  app.set "jsonp callback", true



###
# Authentication shinanigans
###

app.get "/auth", (req, res, next) ->
  if req.user then return res.json _.defaults req.auth,
    user: req.user

  res.json {}

app.del "/auth", (req, res, next) ->
  auths.del req.cookies.plnkr_token, (err) ->
    return next(err) if err
    res.clearCookie "plnkr_auth",
      domain: url.parse(nconf.get("url:api")).host
      path: if nconf.get("nosubdomains") then app.route else "/"
    res.send(204)

app.get "/auths/github", (req, res, next) ->
  return next(new require("./errors").MissingArgument("token")) unless req.query.token

  if req.user then return res.json _.defaults req.auth,
    user: req.user

  request.get "https://api.github.com/user?access_token=#{req.query.token}", (err, response, body) ->
    return next(new require("./errors").Error(err)) if err

    try
      body = JSON.parse(body)
    catch e
      return next(new require("./errors").InvalidJSON)

    return next(new require("./errors").Unauthorized(body)) if response.status >= 400

    # Create a new authorization
    createAuth = (err, user) ->
      return next(err) if err

      auth =
        id: "tok-#{genid()}"
        user_key: user_key
        service: "github"
        service_token: req.query.token

      auths.set auth.id, auth, (err) ->
        return next(err) if err

        json = _.defaults auth,
          user: user

        res.cookie "plnkr_auth", auth.id,
          expires: new Date(Date.now() + 1000 * 60 * 60 * 24 * 7) # One week
          domain: url.parse(nconf.get("url:api")).host
          path: if nconf.get("nosubdomains") then app.route else "/"
        res.json json, 201

    # Create user if not exists
    user_key = "github:#{body.id}"

    users.get user_key, (err, user) ->
      unless user
        user = 
          id: user_key
          login: body.login
          gravatar_id: body.gravatar_id
        users.set user_key, user, createAuth
      else createAuth(null, user)



###
# Plunks
###

async = require("async")

waterfall = (steps, context = {}) ->
  (args..., finish) ->
    stream = _.map steps, (step) -> _.bind(step, context) # Bind to context
    stream.unshift (next) -> next(null, args...) # Add a starter
    
    async.waterfall(stream, finish)


# List plunks
app.get "/plunks", (req, res, next) ->
  pp = Math.max(1, parseInt(req.param("pp", "12"), 10))
  start = Math.max(0, parseInt(req.param("p", "1"), 10) - 1) * pp
  end = start + pp
  
  preparer = waterfall require("./chains/plunks/prepare"), user: req.user, users: users, tokens: req.tokens
  iterator = ([id, plunk], next) -> preparer(id, plunk, next)
  
  plunks.list start, end, (err, list) ->
    if err then next(err)
    else async.map list, iterator, (err, list) ->
      if err then next(err)
      else res.json(list, 200)
  
# Create plunk
app.post "/plunks", (req, res, next) ->
  creater = waterfall require("./chains/plunks/create"), user: req.user, plunks: plunks, tokens: req.tokens
  preparer = waterfall require("./chains/plunks/prepare"), user: req.user, users: users, tokens: req.tokens
  responder = waterfall [creater, preparer]
  
  responder req.body, (err, plunk) ->
    if err then next(err)
    else res.json(plunk, 201)

# Read plunk
app.get "/plunks/:id", (req, res, next) ->
  fetcher = waterfall require("./chains/plunks/fetch"), plunks: plunks
  preparer = waterfall require("./chains/plunks/prepare"), user: req.user, users: users, tokens: req.tokens
  responder = waterfall [fetcher, preparer]
  
  responder req.body, (err, plunks) ->
    if err then next(err)
    else res.json(plunks, 200)

# Delete plunk
app.del "/plunks/:id", (req, res, next) ->
  plunks.get req.params.id, (err, plunk) ->
    if err then next(err)
    else unless plunk then next(new apiErrors.NotFound)
    else unless req.tokens.has(plunk.token) or (req.user and plunk.user == req.user.id) then next(new apiErrors.PermissionDenied)
    else plunks.del req.params.id, (err) ->
      if err then next(err)
      else res.send(204)