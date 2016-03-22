# TiResty [![Appcelerator Titanium](http://www-static.appcelerator.com/badges/titanium-git-badge-sq.png)](http://appcelerator.com/titanium/) [![Appcelerator Alloy](http://www-static.appcelerator.com/badges/alloy-git-badge-sq.png)](http://www.appcelerator.com/)

 REST [Alloy adapter](http://docs.appcelerator.com/titanium/3.0/#!/guide/Alloy_Sync_Adapters_and_Migrations-section-36739597_AlloySyncAdaptersandMigrations-SyncAdapters) which can syncing with local SQLite database. It was developed to be as **simple and fast** as possible. There is no SQL sugar (you can use [squel](https://github.com/hiddentao/squel)), http cache system etc.
 Maybe you better want to use [napp.alloy.adapter.restsql](https://github.com/viezel/napp.alloy.adapter.restsql) if you will not have any performance issues with it.

## Get it

Download latest release archive and put `resty.js` in `app/assets/alloy/sync/` or `app/lib/alloy/sync`

## Use it

### Model definition

You can define model in simular way as with standard sql adapter:
```javascript
exports.definition = {
  config: {
    columns: {
      id: 'integer unique',
      name: 'text',
      api: 'text'
    },
    adapter: {
      type: 'resty',
      collection_name: 'droid',
      idAttribute: 'id',
      urlRoot: 'http://192.168.56.1:9081/droid/'
    }
  }
};
```

Server path must be defined in model config or as option to backbone methods (`fetch`, `create`, `save`, `destroy`). In simplest way it can be done inside model definition with `urlRoot` adapter option. Read [**Url resolving priority**](#url-resolving-priority) if you have more complex way.

Full complex example:
```javascript
exports.definition = {
  config: {
    columns: {
      id: 'integer unique',
      name: 'text',
      api: 'text'
    },
    adapter: {
      type: 'resty',
      collection_name: 'droid',
      idAttribute: 'id',
      mode: 'RemoteFirst',
      urlRoot: 'http://192.168.56.1:9081/droid/',
      debug: true,
      delete: true, 
      merge: true,
      reset: false,
      success: function (resp) {
	      
      },
      error: function (error) {
	      Ti.API.warning("Request failed: " + error);
      }
    }
  }
};
```


### Configuration

Any configuration of sync can be done in two way:
1. `options` - parameters dict to backbone (alloy collection, model) methods (`fetch`, `create`, `save`, `destroy`).
2. `config.adapter` inside model definition

Direct `options` to backbone functions take precedence over `config.adapter`.

Config values with `⨏` symbol can be defined as functions. Most of them called with `_.defaults(options, config.adapter)` parameter if another is not specified as `(⨏) (param1, param2)`. 

#### mode (⨏)

 There are six built-in sync modes: `RemoteOnly`, `LocalOnly`, `Remote`, `Local`, `RemoteFirst`, `LocalFirst`.
 
##### RemoteOnly

 Make request to remote server only; never read from or write to local database.
 
##### LocalOnly
 
 Read from or write to local database only; never make request to remote server.
 
##### Remote
 
 Make remote request and then update local database if the request was successful.
 
##### Local

 Read from or write to local database and then send request to server. Remote request will be skipped if sync method is `read`.

##### RemoteFirst

 Read 

##### LocalFirst
 
 Try to read from or write to local database. Request to remote server as fallback. 

#### debug (default: false)

#### url (⨏, default: null)

#### urlRoot (⨏, default: null)

#### delete (default: true)

#### merge (default: true)

#### reset (default: false)

#### urlparams (⨏, default: {})

#### headers (⨏, default: {})

#### data (⨏, default: null)

#### contentType (⨏, default: 'application/json' if no custom `data` passed, 'application/x-www-form-urlencoded' if `emulateJSON` set, else will not be set)

#### dataType (⨏, default: 'json')

#### type (⨏, default: depends on sync method)

#### emulateJSON (⨏, default: false)

#### emulateHTTP (⨏, default: false)

#### attrs (⨏, default: not used) <sup>*Alloy 1.6 only*</sup>

#### Other Titanium HTTPClient config options

You can set other Titanium HTTPClient config options such as `timeout`, `username`, `password` etc.

### Url resolving priority

Server path for request can be defined in many different ways. You can find priority in which resty and backbone will try to find request url bellow. All of values can be defined as url or function.

#### Model

1. options.url (⨏)
2. adapter.url (⨏)
3. model.url (⨏: this=model) (*no params*) <small>**NB: in alloy<1.6.0 and backbone=0.9.2 `this` can be any**</small>
4. options.urlRoot + model.id (⨏)
5. adapter.urlRoot + model.id (⨏)
6. model.urlRoot + model.id (⨏: this=model) (*no params*) <small>**NB: in alloy<1.6.0 and backbone=0.9.2 `this` can be any**</small>
7. collection.url + model.id (⨏: this=collection) (*no params*) <small>**NB: in alloy<1.6.0 and backbone=0.9.2 `this` can be any**</small>

#### Collection

1. options.url (⨏)
2. adapter.url (⨏)
3. options.urlRoot (⨏) 
4. adapter.urlRoot (⨏)
5. collection.url (⨏: this=collection) (*no params*) <small>**NB: in alloy<1.6.0 and backbone=0.9.2 `this` can be any**</small>