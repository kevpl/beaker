#!/usr/bin/env groovy
@Library('puppet_jenkins_shared_libraries') _

import com.puppet.jenkinsSharedLibraries.BundleInstall
import com.puppet.jenkinsSharedLibraries.BundleExec

String useBundleInstall(String rubyVersion) {
  def bundle_install = new BundleInstall(rubyVersion)
  return bundle_install.bundleInstall
}

String useBundleExec(String rubyVersion, String command) {
  def bundle_exec = new BundleExec(rubyVersion, command)
  return bundle_exec.bundleExec
}

pipeline {
  agent { label 'worker' }

  environment {
    GEM_SOURCE='https://artifactory.delivery.puppetlabs.net/artifactory/api/gems/rubygems/'
    RUBY_VERSION='2.5.1'
  }

  stages {
    stage('install') {
      steps {
        echo 'Bundle Install...'

        sh useBundleInstall(env.RUBY_VERSION)
        sh useBundleExec(env.RUBY_VERSION, 'rake -T')

        echo 'Bundle Install Complete'
      }
    }
    stage('spec testing') {
      steps {
        echo 'Spec Testing using a Rake Task...'

        sh useBundleExec(env.RUBY_VERSION, 'rake test:spec')

        echo 'Spec Testing Complete.'
      }
    }
    stage('acceptance:base testing') {
      parallel {
        stage('ubuntu1604') {
          environment {
            LAYOUT='ubuntu1604-64default.a-64a'
          }
          steps {
            sh useBundleExec(env.RUBY_VERSION, 'rake test:base')
          }
        }
        stage('centos7') {
          environment {
            LAYOUT='centos7-64default.a-64a'
          }
          steps {
            sh useBundleExec(env.RUBY_VERSION, 'rake test:base')
          }
        }
      }
    }
  }
}