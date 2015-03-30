exports.definition =
  config:
    columns:
      id: 'int unique'
      name: 'text'
      api: 'real'

    adapter:
      type: 'resty'
      db_name: 'testdb'
      collection_name: 'droid'
      debug: yes
      idAttribute: 'id'
      url: "http://192.168.56.1:9081/droid"
      rootObject: (resp) ->
        if resp.code
          err = new Error(resp.message)
          err.name = resp.code
          return err
        return resp