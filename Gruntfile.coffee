module.exports = (grunt) ->
  grunt.initConfig
    coffee:
      options: bare: yes
      compile:
        expand: yes
        src: ['resty.coffee', 'tests/*.coffee', 'tests/models/*.coffee']
        ext: '.js'

    execute:
      server: src: ['tests/server.js']

    titanium:
      ios:
        options:
          command: 'build'
          projectDir: 'tests/testapp'
          platform: 'ios'

      android:
        options:
          command: 'build'
          projectDir: 'tests/testapp'
          platform: 'android'

    alloy:
      plugin: options:
        command: 'install'
        args: ['plugin', 'tests/testapp']

    clean: [
      'resty.js',
      'tests/*.js',
      'tests/models/*.js',
      'tests/testapp/build',
      'tests/testapp/plugins',
      'tests/testapp/Resources',
    ]

  grunt.loadNpmTasks('grunt-titanium')
  grunt.loadNpmTasks('grunt-contrib-coffee')
  grunt.loadNpmTasks('grunt-alloy')
  grunt.loadNpmTasks('grunt-execute')
  grunt.loadNpmTasks('grunt-contrib-clean')

  grunt.registerTask('default', ['coffee'])
  grunt.registerTask('server', ['coffee', 'execute:server'])
  grunt.registerTask('test', ['coffee', 'alloy:plugin', 'titanium:android'])