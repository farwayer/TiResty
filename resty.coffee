SQLAdapter = require('alloy/sync/sql')
info = (args...) -> Ti.API.info(args...)


Handlers = _.once ->
  RemoteOnly: remoteOnly    # remote only sync
  LocalOnly: localOnly      # local only sync
  Remote: remote            # remote sync; update locally if success
  Local: local              # local sync; remote sync if success
  RemoteFirst: remoteFirst  # try to sync remote first; 'LocalOnly' as fallback
  LocalFirst: localFirst    # try to sync local first; 'Remote' as fallback
                            # (fetch empty local will initiate 'Remote')


sync = (method, entity, options={}) ->
  options = _.clone(options)
  adapter = _.clone(entity.config.adapter)
  delete adapter.type # prevent shadow backbone http type
  options = _.extend(adapter, options)
  options = _.defaults options,
    delete: yes, merge: yes, reset: no
    mode: 'RemoteFirst'

  mode = _.result(options, 'mode')
  handler = Handlers()[mode]

  info "#{Array(80).join('~')}\nsync in '#{mode}' mode"
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
  rootObject = options.rootObject
  collection = options.collection_name
  success = options.success
  error = options.error

  if isCollection
    entity.url or= options.url
  else
    entity.urlRoot or= options.url

  options.parse = yes

  options.success = (resp) ->
    resp = rootObject(resp, options) if rootObject
    info "remote #{method} '#{collection}' ok; #{resp.length ? 1} values"
    success?(resp)

  options.error = (err) ->
    info "remote #{method} '#{collection}' failed: #{err}"
    error?(err)

  info "remote #{method} '#{collection}'..."
  Alloy.Backbone.sync(method, entity, options)


request = (options) ->
  type = _.result(options, 'type')
  url = _.result(options, 'url')
  urlparams = _.result(options, 'urlparams') or {}
  headers = _.result(options, 'headers') or {}
  data = _.result(options, 'data')
  dataType = _.result(options, 'dataType')
  contentType = options.contentType
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
  xhr.send(data)

  return xhr



# local
localSync = (method, entity, options) ->
  table = options.collection_name
  dbName = options.db_name or ALLOY_DB_DEFAULT
  query = _.result(options, 'query')
  async = _.result(options, 'async')
  isCollection = entityIsCollection(entity)
  sql = getSql(query)

  options.parse = no

  makeLocal = ->
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
      info "remote #{method} '#{table}' ok; #{resp.length ? 1} values"
      options.success?(resp)
    else
      options.error?("Local #{method} '#{table}' failed.")

  info "local #{method} '#{table}': #{JSON.stringify(sql)} ..."
  if async then setTimeout(makeLocal, 0) else makeLocal()


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
  columns = Object.keys(entity.config.columns)
  models = if isCollection then entity.models else [entity]

  dbExecute dbName, yes, sql, (db, rs) ->
    return if sql # custom query was executed

    sqlDeleteAll(db, table) if isCollection
    sqlCreateModelList(db, table, models, columns)

  # create collection is a direct `sync` that was called without backbone
  # return entity so callback will get valid model param
  return if isCollection then entity else entity.toJSON()


localUpdate = (entity, isCollection, dbName, table, sql, options) ->
  columns = Object.keys(entity.config.columns)
  models = if isCollection then entity.models else [entity]

  dbExecute dbName, yes, sql, (db, rs) ->
    return if sql # custom query was executed

    if isCollection and options.reset
      sqlDeleteAll(db, table)
      sqlCreateModelList(db, table, models, columns)
    else
      sqlUpdateModelList(db, table, models, columns, options)

  # update collection is a direct `sync` that was called without backbone
  # return entity so callback will get valid model param
  return if isCollection then entity.toJSON() else entity


localDelete = (entity, isCollection, dbName, table, sql, options) ->
  dbExecute dbName, no, sql, (db, rs) ->
    return if sql # custom query was executed

    if isCollection
      sqlDeleteAll(db, table)
    else
      sqlDeleteModel(db, table, entity)

  # delete collection is a direct `sync` that was called without backbone
  # return entity so callback will get valid model param
  return if isCollection then entity.toJSON() else entity



# sql
sqlCreateModelList = (db, table, models, columns) ->
  query = sqlInsertQuery(table, columns)

  models.map (model) ->
    setRandomId(model) unless model.id
    values = columns.map(model.get, model)
    db.execute(query, values)


sqlUpdateModel = (db, table, model, columns, merge, insertQuery, replaceQuery) ->
  values = columns.map(model.get, model)

  # simple create if no id
  unless model.id
    setRandomId(model)
    return db.execute(insertQuery, values)

  modelFields = model.keys()
  updatedFields = columns.filter (column) -> modelFields.indexOf(column) >= 0

  # replace if all fields was changed or not merge (faster than upsert)
  if updatedFields.length is columns.length or not merge
    return db.execute(replaceQuery, values)

  # upsert
  db.execute(insertQuery, values)
  return unless db.rowsAffected is 0

  # sadly we can't pre-generate update query
  updateQuery = sqlUpdateQuery(table, updatedFields, model.idAttribute)
  updatedValues = updatedFields.map(model.get, model)
  updatedValues.push(model.id)

  db.execute(updateQuery, updatedValues)


sqlUpdateModelList = (db, table, models, columns, options) ->
  return if models.length is 0

  if models.length > 1
    countQuery = sqlCountQuery(table)
    rs = db.execute(countQuery)
    count = parseInt(rs.fieldByName('count'))
    if count is 0
      return sqlCreateModelList(db, table, models, columns)

  insertQuery = sqlInsertQuery(table, columns)
  replaceQuery = sqlReplaceQuery(table, columns)
  merge = options.merge

  ids = models.map (model) ->
    sqlUpdateModel(db, table, model, columns, merge, insertQuery, replaceQuery)
    return model.id

  if options.delete
    idAttribute = models[0].idAttribute
    deleteQuery = sqlDeleteNotIn(table, idAttribute, ids.length)
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


sqlDeleteNotIn = (table, idAttribute, count) ->
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
  rs.close() if rs

  db.execute("COMMIT;") if transaction
  db.close()

  return result


guid = ->
  Math.random().toString(36) + Math.random().toString(36)


setRandomId = (model) ->
  model.set(model.idAttribute, guid())


addUrlParams = (url, urlparams) ->
  urlparams = (for param, value of urlparams
    "#{encodeURIComponent(param)}=#{encodeURIComponent(value)}"
  ).join('&')
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


if Alloy.Backbone.VERSION is '0.9.2'
  Alloy.Backbone.setDomLibrary(ajax: request)
else
  Alloy.Backbone.ajax = request



module.exports.sync = sync
module.exports.beforeModelCreate = SQLAdapter.beforeModelCreate
module.exports.afterModelCreate = SQLAdapter.afterModelCreate