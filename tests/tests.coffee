Ti.API.info('HELLO!')

require('ti-mocha')
should = require('should')

describe 'resty', ->
  describe 'All', ->

  describe 'RemoteOnly', ->
    it 'should end with connection error', (done) ->
      Alloy.createCollection('simple').fetch
        mode: 'RemoteOnly'
        url: 'http://non-existing-url/'
        success: -> done("success callback called")
        error: -> done()

    it 'should receive all droids', (done) ->
      Alloy.createCollection('simple').fetch
        mode: 'RemoteOnly'
        success: (droids) ->
          droids.length.should.be.exactly(12)
          done()
        error: (droids, error) -> done(error)

mocha.run()