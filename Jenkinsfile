#!/usr/bin/env groovy
@Library('puppet_jenkins_shared_libraries') _

pipeline {
  agent any

  environment {
    GEM_SOURCE='https://artifactory.delivery.puppetlabs.net/artifactory/api/gems/rubygems/'
    RUBY_VERSION='2.5.1'
  }

  stages {
    stage('install') {
      steps {
        echo 'Bundle Install...'
        BundleInstall env.RUBY_VERSION
        BundleExec env.RUBY_VERSION, 'rake -T'
      }
    }
  }
}