# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module CylHolePuncher
  EXTENSION_ID      = 'cyl_hole_puncher'
  EXTENSION_NAME    = '圆柱一键打洞 (Hole Puncher)'
  EXTENSION_VERSION = '1.0.0'

  unless file_loaded?(__FILE__)
    loader = File.join(File.dirname(__FILE__), EXTENSION_ID, 'main')
    ex = SketchupExtension.new(EXTENSION_NAME, loader)
    ex.description = '专为圆柱/管线及实体模型设计的快速打洞插件：支持圆柱侧面一圈批量打洞、底面/顶面批量打洞，以及鼠标点哪打哪的交互打洞。'
    ex.version     = EXTENSION_VERSION
    ex.copyright   = '2026'
    ex.creator     = 'CylHolePuncher'
    Sketchup.register_extension(ex, true)
    file_loaded(__FILE__)
  end
end
