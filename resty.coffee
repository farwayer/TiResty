SQLAdapter = require('alloy/sync/sql')


Handlers = _.once ->
  RemoteOnly: remoteOnly    # remote only sync
  LocalOnly: localOnly      # local only sync
  Remote: remote            # remote sync; update locally if success
  Local: local              # local sync; remote sync if success
  RemoteFirst: remoteFirst  # try to sync remote first; 'LocalOnly' as fallback
  LocalFirst: localFirst    # try to sync local first; 'Remote' as fallback
                            # (fetch empty local will initiate 'Remote')


sync = (method, entity, options) ->
  optionsHandler = getHandler(options)
  configHandler = getHandler(entity.config.adapter)
  handler = optionsHandler or configHandler or Handlers().RemoteFirst

  info "#{Array(80).join('~')}\nsync in '#{_.invert(Handlers())[handler]}' mode"
  handler(method, entity, options)

  return entity


# Mode.RemoteOnly
remoteOnly = (method, entity, options) ->
  remoteSync(method, entity, options)


# Mode.LocalOnly
localOnly = (method, entity, options) ->
  localSync(method, entity, options)


# Mode.Remote
remote = (method, entity, options) ->
  success = options.success

  options.success = (resp, status, xhr) ->
    success?(resp, status, xhr)

    # remote sync was ok; update local data
    method = 'update' if method is 'read'

    # prevent to repeat callbacks
    options.success = null
    options.error = null

    localSync(method, entity, options)

  remoteSync(method, entity, options)


# Mode.Local
local = (method, entity, options) ->
  success = options.success

  options.success = (resp, status, xhr) ->
    success?(resp, status, xhr)

    options.success = null
    options.error = null
    remoteSync(method, entity, options)

  localSync(method, entity, options)


# Mode.RemoteFirst
remoteFirst = (method, entity, options) ->
  error = options.error

  options.error = ->
    options.error = error
    localOnly(method, entity, options)

  remote(method, entity, options)


# Mode.LocalFirst
localFirst = (method, entity, options) ->
  error = options.error
  success = options.success

  makeRemote = ->
    options.success = success
    options.error = error
    remote(method, entity, options)

  options.error = makeRemote

  options.success = (resp, status, options) ->
    if method is 'read' and resp.length is 0
      return makeRemote()

    success?(resp, status, options)

  localOnly(method, entity, options)


# remote
remoteSync = (method, entity, options) ->
  rootObject = options.rootObject ? entity.config.adapter.rootObject
  isCollection = entity instanceof Alloy.Backbone.Collection
  success = options.success
  error = options.error

  if isCollection
    entity.url or= entity.config.adapter.url
  else
    entity.urlRoot or= entity.config.adapter.url

  options.parse = yes

  name = entity.config.adapter.collection_name
  info "remote #{method} '#{name}'..."
  prof = new Profiler()

  options.success = (resp, status, xhr) ->
    resp = rootObject(resp, options) if rootObject
    info "remote #{method} ok in #{prof.tick()}; #{resp.length ? 1} values; parsing..."
    success?(resp, status, xhr)
    info "remote parsing complete in", prof.tick()

  options.error = ->
    info "remote #{method} failed in", prof.tick()
    error?()

  Alloy.Backbone.sync(method, entity, options)


request = (options) ->
  type = _.result(options, 'type')
  url = _.result(options, 'url')
  urlparams = _.result(options, 'urlparams')
  headers = _.result(options, 'headers')
  data = _.result(options, 'data')
  dataType = _.result(options, 'dataType')
  contentType = options.contentType
  onError = options.error
  onSuccess = options.success
  beforeSend = options.beforeSend

  xhr = Ti.Network.createHTTPClient(options)

  url = addUrlParams(url, urlparams)
  xhr.open(type, url)

  # headers
  headers['Content-Type'] = contentType
  for header of headers
    value = _.result(headers, header)
    xhr.setRequestHeader(header, value) if value

  # callbacks
  xhr.onerror = (res) ->
    onError?(this, 'http', res.error)

  xhr.onload = ->
    data = switch dataType
      when 'xml' then @responseXML
      when 'text' then @responseText
      when 'json'
        try JSON.parse(@responseText)
        catch error then null
      else @responseData

    if data
      onSuccess?(data, 'ok', this)
    else
      status = if error then 'parse' else 'empty'
      onError?(this, status, error)

  # request
  beforeSend?(xhr)
  xhr.send(data)

  return xhr


# local
localSync = (method, entity, options) ->
  [dbName, table] = getEntityDBConfig(entity)
  query = _.result(options, 'query') or _.result(entity.config.adapter, 'query')
  async = _.result(options, 'async') ? _.result(entity.config.adapter, 'async')
  reset = options.reset ? _.result(entity.config.adapter, 'reset')
  isCollection = entity instanceof Alloy.Backbone.Collection

  sql = getSql(query)

  options.parse = no

  name = entity.config.adapter.collection_name
  info "local #{method} '#{name}': #{JSON.stringify(sql) or 'default query'} ..."
  prof = new Profiler()

  makeQuery = ->
    resp = switch method
      when 'read'
        localRead(entity, isCollection, dbName, table, sql)
      when 'create', 'update'
        localUpdate(entity, isCollection, dbName, table, sql, reset)
      when 'delete'
        localDelete(entity, isCollection, dbName, table, sql)

    if resp
      info "local #{method} ok in #{prof.tick()}; #{resp.length ? 1} values; parsing..."
      options.success?(resp, 'local', null)
      info "local parsing complete in", prof.tick()
    else
      info "local #{method} failed in", prof.tick()
      options.error?()

  if async then setTimeout(makeQuery, 0) else makeQuery()


localRead = (entity, isCollection, dbName, table, sql) ->
  sql or= if isCollection
    ["SELECT * FROM #{table};"]
  else
    ["SELECT * FROM #{table} WHERE #{entity.idAttribute}=?;", entity.id]

  dbExecute dbName, no, (db) ->
    rs = db.execute.apply(db, sql)

    fields = (rs.fieldName(i) for i in [0...rs.fieldCount] by 1)

    resp = while rs.isValidRow()
      attrs = {}
      for i in [0...rs.fieldCount] by 1
        attrs[fields[i]] = rs.field(i)
      rs.next()
      attrs

    rs.close()

    resp = resp[0] unless isCollection
    return resp


localUpdate = (entity, isCollection, dbName, table, sql, reset) ->
  columns = Object.keys(entity.config.columns)
  models = if isCollection then entity.models else [entity]

  dbExecute dbName, yes, (db) ->
    if sql
      db.execute.apply(db, sql)
    else
      sqlDeleteAll(db, table) if reset and isCollection

      models.map (model) ->
        sqlSaveModel(db, table, model, columns)

  # update collection is a direct `sync` called without backbone
  # return entity so callback will get valid model param
  return if isCollection then entity.toJSON() else entity


localDelete = (entity, isCollection, dbName, table, sql) ->
  dbExecute dbName, no, (db) ->
    if isCollection
      sqlDeleteAll(db, table)
    else
      sqlDeleteModel(db, table, entity)

  # delete collection is a direct `sync` called without backbone
  # return entity so callback will get valid model param
  return if isCollection then entity.toJSON() else entity


# sql
sqlSaveModel = (db, table, model, columns) ->
  # TODO: optimize
  unless model.id
    model.set(model.idAttribute, guid(), silent: yes)

  fields = _.intersection(model.keys(), columns)
  sqlQ = Array(fields.length + 1).join('?').split('').join()
  sqlFields = fields.join()
  sqlSet = fields.map((column) -> column + '=?').join()

  insert = "INSERT OR IGNORE INTO #{table} (#{sqlFields}) VALUES (#{sqlQ});"
  update = "
    UPDATE #{table} SET #{sqlSet} WHERE CHANGES()=0 AND #{model.idAttribute}=?;
  "

  values = fields.map(model.get, model)
  db.execute(insert, values)

  values.push(model.id)
  db.execute(update, values)


sqlDeleteAll = (db, table) ->
  query = "DELETE FROM #{table};"
  db.execute(query)


sqlDeleteModel = (db, table, model) ->
  query = "DELETE FROM #{table} WHERE #{model.idAttribute}=?;"
  db.execute(query, model.id)


# helpers
getEntityDBConfig = (entity) ->
  adapter = entity.config.adapter
  dbName = adapter.db_name or ALLOY_DB_DEFAULT
  table = adapter.collection_name

  return [dbName, table]


dbExecute = (dbName, transaction, action) ->
  db = Ti.Database.open(dbName)
  db.execute("BEGIN;") if transaction
  result = action(db)
  db.execute("COMMIT;") if transaction
  db.close()
  return result


guid = ->
  Math.random().toString(36) + Math.random().toString(36)


addUrlParams = (url, urlparams) ->
  urlparams = (for param, value of urlparams
    "#{encodeURIComponent(param)}=#{encodeURIComponent(value)}"
  ).join('&')
  return url unless urlparams

  delimiter = if url.indexOf('?') is -1 then '?' else '&'
  return url + delimiter + urlparams


getHandler = (options) ->
  Handlers()[_.result(options, 'mode')]


getSql = (query) ->
  return null unless query

  if _.isObject(query)
    statement = _.result(query, 'statement') or _.result(query, 'text')
    params = _.result(query, 'params') or _.result(query, 'values') or []
    return [statement, params]
  else
    return [query]


if Alloy.Backbone.VERSION is '0.9.2'
  Alloy.Backbone.setDomLibrary(ajax: request)
else
  Alloy.Backbone.ajax = request


module.exports.sync = sync
module.exports.beforeModelCreate = SQLAdapter.beforeModelCreate
module.exports.afterModelCreate = SQLAdapter.afterModelCreate