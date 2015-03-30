require('ti-mocha')
should = require('should')

jsonDump = (obj) ->
  Ti.API.debug(JSON.stringify(obj, null, 2))

describe 'resty', ->
  describe 'All', ->

  describe 'RemoteOnly', ->
    it 'should end with connection error', (done) ->
      Alloy.createCollection('droid').fetch
        mode: 'RemoteOnly'
        url: 'http://non-existing-url/'
        success: -> done(new Error("'success' callback called - bad"))
        error: -> done()

    it 'should receive all droids', (done) ->
      Alloy.createCollection('droid').fetch
        mode: 'RemoteOnly'
        success: (droids) ->
          droids.should.have.length(12)
          done()
        error: (droids, err) -> done(err)

    it 'should receive Gingerbread with /droid/api/2.3 (custom url)', (done) ->
      droids = Alloy.createCollection('droid')
      droids.fetch
        mode: 'RemoteOnly'
        url: droids.config.adapter.urlRoot + 'api/2.3'
        success: (droids) ->
          droids.at(0).get('name').should.be.exactly('Gingerbread')
          done()
        error: (droids, err) -> done(err)

    it 'should failed with "InvalidParam"', (done) ->
      droids = Alloy.createCollection('droid')
      droids.fetch
        mode: 'RemoteOnly'
        url: droids.config.adapter.urlRoot + 'api/1232.3'
        success: -> done(new Error("'success' callback called - bad"))
        error: (droids, err) ->
          err.name.should.be.exactly('InvalidParam')
          done()

    it 'should fetch model by id', (done) ->
      Alloy.createCollection('droid').fetch
        mode: 'Remote'
        success: (droids) ->
          droids.at(0).fetch
            mode: 'Remote'
            success: (model) ->
              model.get('name').should.endWith('NEW')
              done()
            error: (droids, err) -> done(err)
        error: (droids, err) -> done(err)

mocha.run()