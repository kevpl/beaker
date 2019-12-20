#!/usr/bin/env groovy
@Library('puppet_jenkins_shared_libraries')

import com.puppet.jenkinsSharedLibraries.BundleInstall
import com.puppet.jenkinsSharedLibraries.BundleExec

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
        def setup_gems = new BundleInstall(env.RUBY_VERSION)
        def rake_t = new BundleExec(env.RUBY_VERSION, 'rake -T')

        sh setup_gems.bundleInstall
        sh rake_t.bundleExec
        echo 'Bundle Install Complete'
      }
    }
  }
}