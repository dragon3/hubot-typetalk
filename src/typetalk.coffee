HTTPS          = require 'https'
Request        = require 'request'
{EventEmitter} = require 'events'
Package        = require '../package'
Hubot          = require 'hubot'

class Typetalk extends Hubot.Adapter
  # override
  send: (envelope, strings...) ->
    for string in strings
      @bot.Topic(envelope.room).create string, {}, (err, data) =>
        @robot.logger.error "Typetalk send error: #{err}" if err?

  reply: (envelope, strings...) ->
    @send envelope, strings.map((str) -> "@#{envelope.user.name} #{str}")...

  # override
  run: ->
    options =
      clientId: process.env.HUBOT_TYPETALK_CLIENT_ID
      clientSecret: process.env.HUBOT_TYPETALK_CLIENT_SECRET
      rooms: process.env.HUBOT_TYPETALK_ROOMS
      apiRate: process.env.HUBOT_TYPETALK_API_RATE

    bot = new TypetalkStreaming options, @robot
    @bot = bot

    bot.on 'message', (topicId, id, account, message) =>
      user = @robot.brain.userForId account.id,
        name: account.name
        avatarImageUrl: account.imageUrl,
        room: topicId
      if account.id != @bot.info.id
        @receive new Hubot.TextMessage user, message, id

    bot.Me (err, data) =>
      bot.info = data.account
      bot.name = bot.info.name

    @emit 'connected'

exports.use = (robot) ->
  new Typetalk robot

class TypetalkStreaming extends EventEmitter
  constructor: (options, @robot) ->
    unless options.clientId? and options.clientSecret? and options.rooms? and options.apiRate?
      @robot.logger.error \
        'Not enough parameters provided. ' \
        + 'Please set client id, client secret and rooms'
      process.exit 1

    @clientId = options.clientId
    @clientSecret = options.clientSecret
    @rooms = options.rooms.split ','
    @rate = parseInt options.apiRate, 10
    @host = 'typetalk.in'

    unless @rate > 0
      @robot.logger.error 'API rate must be greater then 0'
      process.exit 1

  Me: (callback) ->
    @get '/profile', "", callback
    for room in @rooms
      @Topic(room).listen()

  Topics: (callback) ->
    @get '/topics', "", callback

  Topic: (id) ->
    get: (opts, callback) =>
      @get "/topics/#{id}", "", callback

    create: (message, opts, callback) =>
      data =
        message: message
      @post "/topics/#{id}", data, callback

    listen: =>
      firstSkiped = false
      lastPost = 0
      setInterval =>
        @Topic(id).get {}, (err, data) =>
          if not firstSkiped
            for post in data.posts
              if lastPost < post.id
                lastPost = post.id
            firstSkiped = true
            return

          for post in data.posts
            if lastPost < post.id
              lastPost = post.id
              @emit 'message',
                 data.topic.id,
                 post.id,
                 post.account,
                 post.message
      , 1000 / (@rate / (60 * 60))

  get: (path, body, callback) ->
    @request "GET", path, body, callback

  post: (path, body, callback) ->
    @request "POST", path, body, callback

  put: (path, body, callback) ->
    @request "PUT", path, body, callback

  delete: (path, body, callback) ->
    @request "DELETE", path, body, callback

  updateAccessToken: (callback) ->
    logger = @robot.logger

    options =
      url: "https://#{@host}/oauth2/access_token"
      form:
        client_id: @clientId
        client_secret: @clientSecret
        grant_type: 'client_credentials'
        scope: 'my,topic.read,topic.post'
      headers:
        'User-Agent': "#{Package.name} v#{Package.version}"

    Request.post options, (err, res, body) =>
      if err
        logger.error "Typetalk HTTPS response error: #{err}"
        if callback
          callback err, {}

      if res.statusCode >= 400
        throw new Error "Typetalk API returned unexpected status code: " \
          + "#{res.statusCode}"

      json = try JSON.parse body catch e then body or {}
      @accessToken = json.access_token
      @refreshToken = json.refresh_token

      if callback
        callback null, json

  request: (method, path, body, callback) ->
    logger = @robot.logger

    req = (err, data) =>
      options =
        url: "https://#{@host}/api/v1#{path}"
        method: method
        headers:
          Authorization: "Bearer #{@accessToken}"
          'User-Agent': "#{Package.name} v#{Package.version}"

      if method is 'POST'
        options.form = body
      else
        options.body = body

      Request options, (err, res, body) =>
        if err
          logger.error "Typetalk response error: #{err}"
          if callback
            callback err, {}

        if res.statusCode >= 400
          @updateAccessToken req

        if callback
          json = try JSON.parse body catch e then body or {}
          callback null, json

    if @accessToken
      req()
    else
      @updateAccessToken req

