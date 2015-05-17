SQLAdapter = require('alloy/sync/sql')


Handlers = _.once ->
  RemoteOnly: remoteOnly    # remote only sync
  LocalOnly: localOnly      # local only sync
  Remote: remote            # remote sync; update locally if success
  Local: local              # local sync; remote sync if success
  RemoteFirst: remoteFirst  # try to sync remote first; 'LocalOnly' as fallback
  LocalFirst: localFirst    # try to sync local first; 'Remote' as fallback
                            # (fetch empty local will initiate 'Remote')


sync = (method, entity, options={}) ->
  adapter = _.clone(entity.config.adapter)
  delete adapter.type # prevent shadow backbone http type
  _.defaults(options, adapter)
  _.defaults options,
    delete: yes, merge: yes, reset: no
    mode: 'RemoteFirst'
    columns: Object.keys(entity.config.columns)
  options.attrs = _.result(options, 'attrs')
  options.syncNo = requestId()

  mode = _.result(options, 'mode')
  handler = Handlers()[mode]

  syncDebug(method, mode, entity, options)
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

    # remote sync was ok; save local data
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

    # prevent to repeat callbacks
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
  isCollection = entityIsCollection(entity)
  urlRoot = _.result(options, 'urlRoot')
  emulateHTTP = _.result(options, 'emulateHTTP')
  emulateJSON = _.result(options, 'emulateJSON')
  rootObject = options.rootObject
  success = options.success
  error = options.error

  if urlRoot
    if isCollection
      entity.url = urlRoot
    else
      entity.urlRoot = urlRoot

  options.parse = yes

  options.success = (resp) ->
    resp = rootObject(resp, options) if rootObject
    if err = checkError(resp)
      return error?(err)

    remoteSuccessDebug(method, options, resp)
    success?(resp)

  options.error = (err) ->
    remoteErrorDebug(method, options, err)
    error?(err)

  # backbone 0.9.2
  Alloy.Backbone.emulateHTTP = emulateHTTP if emulateHTTP?
  Alloy.Backbone.emulateJSON = emulateJSON if emulateJSON?

  remoteSyncDebug(method, options)
  Alloy.Backbone.sync(method, entity, options)


request = (options) ->
  type = _.result(options, 'type')
  url = _.result(options, 'url')
  urlparams = _.result(options, 'urlparams') or {}
  headers = _.result(options, 'headers') or {}
  data = _.result(options, 'data')
  dataType = _.result(options, 'dataType')
  contentType = _.result(options, 'contentType')
  error = options.error
  success = options.success
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
    error?(res.error)

  xhr.onload = ->
    data = switch dataType
      when 'xml' then @responseXML
      when 'text' then @responseText
      when 'json'
        try JSON.parse(@responseText)
        catch err then null
      else @responseData

    if data
      success?(data)
    else
      error?(err ? "Empty response")

  # request
  beforeSend?(xhr)

  requestDebug(options, type, url)
  xhr.send(data)

  return xhr



# local
localSync = (method, entity, options) ->
  table = options.collection_name
  dbName = options.db_name or ALLOY_DB_DEFAULT
  query = _.result(options, 'query')
  isCollection = entityIsCollection(entity)
  sql = getSql(query)

  options.parse = no

  localSyncDebug(method, options, sql, table)

  resp = switch method
    when 'read'
      localRead(entity, isCollection, dbName, table, sql, options)
    when 'create'
      localCreate(entity, isCollection, dbName, table, sql, options)
    when 'update'
      localUpdate(entity, isCollection, dbName, table, sql, options)
    when 'delete'
      localDelete(entity, isCollection, dbName, table, sql, options)

  if resp
    localSuccessDebug(method, options, table, resp)
    options.success?(resp)
  else
    localErrorDebug(method, options, table)
    options.error?("Empty response")


localRead = (entity, isCollection, dbName, table, sql, options) ->
  sql or= if isCollection
    [sqlSelectAllQuery(table)]
  else
    [sqlSelectModelQuery(table, entity.idAttribute), entity.id]

  dbExecute dbName, no, sql, (db, rs) ->
    resp = parseSelectResult(rs)
    resp = resp[0] unless isCollection
    return resp


localCreate = (entity, isCollection, dbName, table, sql, options) ->
  columns = options.columns
  models = if isCollection then entity.models else [entity]

  dbExecute dbName, yes, sql, (db, rs) ->
    return if sql # custom query was executed

    sqlDeleteAll(db, table) if isCollection
    sqlCreateModelList(db, table, models, columns)

  # creating collection is a direct `sync` that was called without backbone
  # return entity so callback will get valid model param
  if isCollection then entity else entity.toJSON()


localUpdate = (entity, isCollection, dbName, table, sql, options) ->
  columns = options.columns
  models = if isCollection then entity.models else [entity]

  dbExecute dbName, yes, sql, (db, rs) ->
    return if sql # custom query was executed

    if isCollection and options.reset
      sqlDeleteAll(db, table)
      sqlCreateModelList(db, table, models, columns)
    else
      sqlUpdateModelList(db, table, models, columns, isCollection, options)

  # updating collection is a direct `sync` that was called without backbone
  # return entity so callback will get valid model param
  if isCollection then entity.toJSON() else entity


localDelete = (entity, isCollection, dbName, table, sql, options) ->
  dbExecute dbName, no, sql, (db, rs) ->
    return if sql # custom query was executed

    if isCollection
      sqlDeleteAll(db, table)
    else
      sqlDeleteModel(db, table, entity)

  # removing collection is a direct `sync` that was called without backbone
  # return entity so callback will get valid model param
  if isCollection then entity.toJSON() else entity



# sql
sqlCreateModelList = (db, table, models, columns) ->
  query = sqlInsertQuery(table, columns)

  models.map (model) ->
    setRandomId(model) unless model.id
    values = getValues(model, columns)
    db.execute(query, values)


sqlUpdateModel = (db, table, model, columns, merge, insertQuery, replaceQuery) ->
  values = getValues(model, columns)

  # simple create if no id
  unless model.id
    setRandomId(model)
    return db.execute(insertQuery, values)

  modelFields = Object.keys(model.attributes)
  updatedFields = columns.filter (column) -> modelFields.indexOf(column) >= 0

  # replace if all fields was changed or not merge (faster than upsert)
  if updatedFields.length is columns.length or not merge
    return db.execute(replaceQuery, values)

  # upsert
  db.execute(insertQuery, values)
  return unless db.rowsAffected is 0

  updateQuery = sqlUpdateQuery(table, updatedFields, model.idAttribute)
  updatedValues = getValues(model, updatedFields)
  updatedValues.push(model.id)
  db.execute(updateQuery, updatedValues)


sqlUpdateModelList = (db, table, models, columns, isCollection, options) ->
  return if models.length is 0

  if models.length > 1
    countQuery = sqlCountQuery(table)
    rs = db.execute(countQuery)
    count = rs.fieldByName('count')
    if count is 0
      return sqlCreateModelList(db, table, models, columns)

  insertQuery = sqlInsertQuery(table, columns)
  replaceQuery = sqlReplaceQuery(table, columns)
  # sadly we can't pre-generate update query (columns can be variable)
  merge = options.merge

  ids = models.map (model) ->
    sqlUpdateModel(db, table, model, columns, merge, insertQuery, replaceQuery)
    return model.id

  if isCollection and options.delete
    idAttribute = models[0].idAttribute
    deleteQuery = sqlDeleteNotInQuery(table, idAttribute, ids.length)
    db.execute(deleteQuery, ids)


sqlDeleteAll = (db, table) ->
  query = sqlDeleteAllQuery(table)
  db.execute(query)


sqlDeleteModel = (db, table, model) ->
  query = sqlDeleteModelQuery(table, model.idAttribute)
  db.execute(query, model.id)


# sql helpers
sqlDeleteAllQuery = (table) ->
  "DELETE FROM #{table};"


sqlDeleteModelQuery = (table, idAttribute) ->
  "DELETE FROM #{table} WHERE #{idAttribute}=?;"


sqlDeleteNotInQuery = (table, idAttribute, count) ->
  sqlQ = sqlQList(count)
  "DELETE FROM #{table} WHERE #{idAttribute} NOT IN #{sqlQ}"


sqlInsertQuery = (table, columns) ->
  sqlColumns = sqlColumnList(columns)
  sqlQ = sqlQList(columns.length)
  "INSERT OR IGNORE INTO #{table} #{sqlColumns} VALUES #{sqlQ};"


sqlReplaceQuery = (table, columns) ->
  sqlColumns = sqlColumnList(columns)
  sqlQ = sqlQList(columns.length)
  "REPLACE INTO #{table} #{sqlColumns} VALUES #{sqlQ};"


sqlUpdateQuery = (table, columns, idAttribute) ->
  sqlSet = sqlSetList(columns)
  "UPDATE #{table} SET #{sqlSet} WHERE #{idAttribute}=?;"


sqlSelectAllQuery = (table) ->
  "SELECT * FROM #{table};"


sqlSelectModelQuery = (table, idAttribute) ->
  "SELECT * FROM #{table} WHERE #{idAttribute}=?;"


sqlCountQuery = (table) ->
  "SELECT COUNT(*) AS count FROM #{table}"


sqlQList = (count) ->
  "(#{Array(count + 1).join('?,')[...-1]})"


sqlColumnList = (columns) ->
  "(#{columns.join()})"


sqlSetList = (columns) ->
  columns.map((column) -> "#{column}=?").join()


parseSelectResult = (rs) ->
  fields = (rs.fieldName(i) for i in [0...rs.fieldCount] by 1)

  while rs.isValidRow()
    attrs = {}
    for i in [0...rs.fieldCount] by 1
      attrs[fields[i]] = rs.field(i)
    rs.next()
    attrs



# helpers
dbExecute = (dbName, transaction, sql, action) ->
  action or= (db, rs) -> rs

  db = Ti.Database.open(dbName)
  db.execute("BEGIN;") if transaction

  rs = db.execute.apply(db, sql) if sql
  result = action(db, rs)
  rs?.close()

  db.execute("COMMIT;") if transaction
  db.close()

  return result


guid = ->
  Math.random().toString(36) + Math.random().toString(36)


setRandomId = (model) ->
  model.set(model.idAttribute, guid())


addUrlParams = (url, urlparams) ->
  encode = encodeURIComponent
  urlparams = ("#{encode(p)}=#{encode(v)}" for p, v of urlparams).join('&')
  return url unless urlparams

  delimiter = if url.indexOf('?') is -1 then '?' else '&'
  return url + delimiter + urlparams


getSql = (query) ->
  return null unless query

  if _.isObject(query)
    statement = _.result(query, 'statement') or _.result(query, 'text')
    params = _.result(query, 'params') or _.result(query, 'values') or []
    return [statement, params]
  else
    return [query]


entityIsCollection = (entity) ->
  entity instanceof Alloy.Backbone.Collection


getValues = (model, fields) ->
  fields.map (field) ->
    value = model.get(field)
    if _.isObject(value) then JSON.stringify(value) else value


checkError = (resp) ->
  if toString.call(resp) is '[object Error]'
    return resp

  if _.isString(resp)
    return new Error(resp)

  if resp
    return null

  return new Error("Response is empty")


requestId = (-> id = 0; -> id++)()



# debug
info = (args...) -> Ti.API.info("[TiResty]", args...)
warn = (args...) -> Ti.API.warn("[TiResty]", args...)


syncDebug = (method, mode, entity, options) ->
  if options.debug
    collection = options.collection_name
    entityType = if entityIsCollection(entity) then 'collection' else 'model'
    syncNo = options.syncNo
    info "[#{syncNo}*] #{method} ##{mode} '#{collection}' #{entityType}"
    info "options: #{JSON.stringify(options)}"


remoteSyncDebug = (method, options) ->
  if options.debug
    syncNo = options.syncNo
    collection = options.collection_name
    info "[#{syncNo}] remote #{method} '#{collection}'..."


remoteSuccessDebug = (method, options, resp) ->
  if options.debug
    count = resp.length ? 1
    syncNo = options.syncNo
    collection = options.collection_name
    info "[#{syncNo}] remote #{method} '#{collection}' ok"
    info "#{count} values: #{JSON.stringify(resp)}"


remoteErrorDebug = (method, options, err) ->
  if options.debug
    syncNo = options.syncNo
    collection = options.collection_name
    warn "[#{syncNo}] remote #{method} '#{collection}' failed: #{err}"


requestDebug = (options, type, url) ->
  if options.debug
    syncNo = options.syncNo
    info "[#{syncNo}] #{type} #{url}"


localSyncDebug = (method, options, sql, table) ->
  if options.debug
    syncNo = options.syncNo
    sqlDebug = if sql then JSON.stringify(sql) else "default sql"
    info "[#{syncNo}] local #{method} '#{table}': #{sqlDebug} ..."


localSuccessDebug = (method, options, table, resp) ->
  if options.debug
    syncNo = options.syncNo
    count = resp.length ? 1
    info "[#{syncNo}] local #{method} '#{table}' ok; #{count} values"


localErrorDebug = (method, options, table) ->
  if options.debug
    syncNo = options.syncNo
    warn "[#{syncNo}] local #{method} '#{table}' failed"



if Alloy.Backbone.VERSION is '0.9.2'
  Alloy.Backbone.setDomLibrary(ajax: request)
else
  Alloy.Backbone.ajax = request



module.exports.sync = sync
module.exports.beforeModelCreate = SQLAdapter.beforeModelCreate
module.exports.afterModelCreate = SQLAdapter.afterModelCreate