SQL = require('alloy/sync/sql')


Mode =
  RemoteOnly: 1   # remote only sync
  LocalOnly: 2    # local only sync
  Remote: 3       # remote sync; update locally if success
  Local: 4        # local sync; remote sync if success
  RemoteFirst: 5  # try to sync remote first; 'LocalOnly' as fallback
  LocalFirst: 6   # try to sync local first; 'Remote' as fallback
                  # (in this mode 'read' empty local will initiate 'Remote')

handlers = {}
initHandlers = ->
  handlers[Mode.RemoteOnly] = remoteOnly
  handlers[Mode.LocalOnly] = localOnly
  handlers[Mode.Remote] = remote
  handlers[Mode.Local] = local
  handlers[Mode.RemoteFirst] = remoteFirst
  handlers[Mode.LocalFirst] = localFirst


sync = (method, entity, options) ->
  optionsMode = _.result(options, 'mode')
  configMode = _.result(entity.config.adapter, 'mode')
  mode = optionsMode or configMode or Mode.RemoteFirst

  unless handler = handlers[mode]
    throw "Invalid mode #{mode}"

  handler(method, entity, options)


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

  options.error = ->
    makeRemote()

  options.success = (resp, status, options) ->
    if method is 'read' and resp.length is 0
      return makeRemote()

    success?(resp, status, options)

  localOnly(method, entity, options)


# remote sync
remoteSync = (method, entity, options) ->
  success = options.success
  error = options.error

  options.success = (resp, status, xhr) ->
    info "remote #{method} ok"
    success?(resp, status, xhr)

  options.error = ->
    info "remote #{method} error"
    error?()

  info "remote #{method}..."
  Alloy.Backbone.sync(method, entity, options)


# local sync
localSync = (method, entity, options) ->
  async = _.result(options, 'async') ? _.result(entity.config.adapter, 'async')

  info 'localSync before', entity.length
  makeQuery = ->
    info "local #{method}..."
    resp = switch method
      when 'read' then localRead(entity)
      when 'create', 'update' then localUpdate(entity, !options.add)
      when 'delete' then localDelete(entity)

    info 'localSync after', resp.length
    if resp
      info "local #{method} ok"
      options.success?(resp, 'local', null)
    else
      info "local #{method} error"
      options.error?()

  if async then setTimeout(makeQuery, 0) else makeQuery()


# request
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


# local read
localRead = (entity) ->
  # TODO: use SQL.sync() when next version will be released
  [dbName, table] = getEntityDBConfig(entity)
  isCollection = entity instanceof Alloy.Backbone.Collection

  condition = if isCollection then "" else "WHERE #{entity.idAttribute}=?"
  sql = "SELECT * FROM #{table} #{condition};"

  dbExecute dbName, no, (db) ->
    rs = if isCollection
      db.execute(sql)
    else
      db.execute(sql, entity.id)

    columns = (rs.fieldName(i) for i in [0...rs.fieldCount] by 1)

    resp = while rs.isValidRow()
      attrs = {}
      for i in [0...rs.fieldCount] by 1
        attrs[columns[i]] = rs.field(i)
      rs.next()
      attrs

    rs.close()

    if isCollection
      entity.length = resp.length
      return resp
    else
      return resp[0]


# local update, create
localUpdate = (entity, reset) ->
  [dbName, table] = getEntityDBConfig(entity)
  columns = Object.keys(entity.config.columns)
  isCollection = entity instanceof Alloy.Backbone.Collection

  models = if isCollection then entity.models else [entity]

  # for optimization
  sqlQ = Array(columns.length + 1).join('?').split('').join(',')
  sqlColumns = columns.join(',')
  sql = "REPLACE INTO #{table} (#{sqlColumns}) VALUES (#{sqlQ});"

  dbExecute dbName, yes, (db) ->
    sqlDeleteAll(db, table) if reset

    prof = new Profiler()

    models.map (model) ->
      sqlSaveModel(db, model, columns, sql)

    info 'wrote in', prof.tick()

  return entity.toJSON()


# localDelete
localDelete = (entity) ->
  [dbName, table] = getEntityDBConfig(entity)

  dbExecute dbName, no, (db) ->
    sqlDeleteModel(db, table, entity)

  return entity.toJSON()


# sql
sqlSaveModel = (db, model, columns, sql) ->
  unless model.id
    model.set(model.idAttribute, guid(), silent: yes)

  values = columns.map(model.get, model)
  db.execute(sql, values)


sqlDeleteAll = (db, table) ->
  sql = "DELETE FROM #{table};"
  db.execute(sql)


sqlDeleteModel = (db, table, model) ->
  sql = "DELETE FROM #{table} WHERE #{model.idAttribute}=?;"
  db.execute(sql, model.id)


# local helpers
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


# remote helpers
addUrlParams = (url, urlparams) ->
  urlparams = (for param, value of urlparams
    "#{encodeURIComponent(param)}=#{encodeURIComponent(value)}"
  ).join('&')
  return url unless urlparams

  delimiter = if url.indexOf('?') is -1 then '?' else '&'
  return url + delimiter + urlparams


initHandlers()
Alloy.Backbone.setDomLibrary(ajax: request)

module.exports.Mode = Mode
module.exports.sync = sync
module.exports.beforeModelCreate = SQL.beforeModelCreate
module.exports.afterModelCreate = SQL.afterModelCreate