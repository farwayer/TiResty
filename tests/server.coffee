_ = require('underscore')

restify = require('restify')

server = restify.createServer
  name: 'test api'
  version: '1.0.0'
server.use(restify.acceptParser(server.acceptable))
server.use(restify.queryParser())
server.use(restify.bodyParser())


droids = [
  {id: 1, api: 1.0, name: 'Apple Pie'}
  {id: 2, api: 1.1, name: 'Banana Bread'}
  {id: 3, api: 1.5, name: 'Cupcake'}
  {id: 4, api: 1.6, name: 'Donut'}
  {id: 5, api: 2.0, name: 'Eclair'}
  {id: 6, api: 2.2, name: 'Froyo'}
  {id: 7, api: 2.3, name: 'Gingerbread'}
  {id: 8, api: 3.0, name: 'Honeycomb'}
  {id: 9, api: 4.0, name: 'Ice Cream Sandwich'}
  {id: 10, api: 4.1, name: 'Jelly Bean'}
  {id: 11, api: 4.4, name: 'Kit Kat'}
  {id: 12, api: 5.0, name: 'Lollipop'}
]


server.get '/simple', (req, res, next) ->
  res.send(data: droids)
  next()


server.get '/simple/:api', (req, res, next) ->
  api = parseFloat(req.params['api'])
  if api is NaN
    res.send(message: "Api must be float number", code: "InvalidParam")
    next()
    return

  droid = _(droids).findWhere(api: api)
  unless droid
    [..., last] = droids
    if api > last.api
      res.send(message: "Time machine?", code: "InvalidParam")
      next()
      return

    res.send(message: "Invalid api", code: "InvalidParam")
    next()

  res.send(droid)
  next()


server.get '/randomId', (req, res, next) ->
  droidsCopy = droids[..]
  droidsCopy.map (droid) -> droid.id = Math.random().toString(36)
  res.send(data: droidsCopy)
  next()


lastNew = 0
server.get '/new', (req, res, next) ->
  res.send(droids[lastNew..lastNew+1])
  lastNew += 2
  next()


server.get '/stop', ->
  server.close()

server.listen 9081, ->
  console.log('%s listening at %s', server.name, server.url)
