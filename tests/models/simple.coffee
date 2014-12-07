exports.definition =
  config:
    columns:
      name: 'text'
      api: 'real'

    adapter:
      type: 'resty'
      db_name: 'testdb'
      collection_name: 'simple'
      url: "http://localhost:9081/simple"
