# frozen_string_literal: true

require 'sketchup.rb'

module CylHolePuncher
  # 记住用户在当前会话中上次输入的参数
  @last_side_opts = nil
  @last_end_opts  = nil
  @last_click_opts = {
    diameter_mm: 20.0,
    depth_mode: '穿透整个模型',
    depth_mm: 50.0,
    segments: 36,
    shape: '圆孔'
  }

  class << self
    attr_accessor :last_click_opts

    # ------------------------------------------------------------
    # 数学与几何辅助函数
    # ------------------------------------------------------------
    def scale_vec(vec, factor)
      Geom::Vector3d.new(vec.x * factor, vec.y * factor, vec.z * factor)
    end

    def build_orthonormal_frame(axis_vec)
      axis = axis_vec.normalize
      ref  = axis.parallel?(Z_AXIS) ? X_AXIS : Z_AXIS
      u    = axis.cross(ref).normalize
      v    = axis.cross(u).normalize
      [u, v, axis]
    end

    # 生成一个严格闭合的实体“钻头”群组（圆柱或方柱）
    # p_start: 起点；axis_vec: 延伸方向；radius: 半径（方孔为半边长）；length: 长度
    def create_cutter_group(parent_ents, p_start, axis_vec, radius, length, segments, shape)
      grp  = parent_ents.add_group
      ents = grp.entities

      u, v, axis = build_orthonormal_frame(axis_vec)
      tr = Geom::Transformation.axes(p_start, u, v, axis)

      if shape == '方孔'
        r = radius
        pts = [
          Geom::Point3d.new(-r, -r, 0),
          Geom::Point3d.new( r, -r, 0),
          Geom::Point3d.new( r,  r, 0),
          Geom::Point3d.new(-r,  r, 0)
        ]
        face = ents.add_face(pts)
      else
        edges = ents.add_circle(ORIGIN, Z_AXIS, radius, segments)
        face  = ents.add_face(edges)
      end

      raise '无法创建打洞钻头截面，请检查孔径是否过小。' unless face

      # SketchUp 在 Z=0 平面画出的面默认法线朝 -Z，必须翻转为 +Z 再正方向推拉
      face.reverse! if face.normal.dot(Z_AXIS) < 0
      face.pushpull(length)

      grp.transform!(tr)
      grp
    end

    # 获取一个面内部保证位于面上的采样点（避免凹面/环形面的 bounds.center 落到面外）
    def face_interior_point(face)
      mesh = face.mesh(0)
      if mesh.count_polygons > 0
        pts = mesh.polygon_points_at(1)
        if pts && pts.length >= 3
          cx = (pts[0].x + pts[1].x + pts[2].x) / 3.0
          cy = (pts[0].y + pts[1].y + pts[2].y) / 3.0
          cz = (pts[0].z + pts[1].z + pts[2].z) / 3.0
          return Geom::Point3d.new(cx, cy, cz)
        end
      end
      face.bounds.center
    end

    # 判断点 wpt 是否严格落在钻头体积内部（用于非实体模型交错删面）
    def point_inside_cutter?(wpt, spec)
      u, v, axis = build_orthonormal_frame(spec[:axis])
      rel = wpt - spec[:p_start]
      h   = rel.dot(axis)
      return false if h < -1.0e-4 || h > spec[:length] + 1.0e-4

      rad_vec = rel - scale_vec(axis, h)
      limit   = spec[:radius] * 0.995
      if spec[:shape] == '方孔'
        rad_vec.dot(u).abs < limit && rad_vec.dot(v).abs < limit
      else
        rad_vec.length < limit
      end
    end

    # 复制原群组/组件的常见属性到布尔运算后的新群组
    def copy_entity_attrs(src_meta, dst)
      return unless dst && dst.valid?

      dst.name = src_meta[:name] if src_meta[:name] && !src_meta[:name].empty?
      dst.layer = src_meta[:layer] if src_meta[:layer] && src_meta[:layer].valid?
      dst.material = src_meta[:material] if src_meta[:material]
      dst.casts_shadows = src_meta[:casts_shadows] unless src_meta[:casts_shadows].nil?
      dst.receives_shadows = src_meta[:receives_shadows] unless src_meta[:receives_shadows].nil?
    end

    def capture_entity_attrs(entity)
      {
        name: entity.name,
        layer: entity.layer,
        material: entity.material,
        casts_shadows: entity.casts_shadows?,
        receives_shadows: entity.receives_shadows?
      }
    end

    # ------------------------------------------------------------
    # 核心打洞引擎：优先实体布尔减法（含小尺寸防破面自动放大100倍），
    # 若原模型非闭合实体则自动降级为【模型交错】表面挖洞
    # ------------------------------------------------------------
    def execute_punch(model, parent_ents, target, specs, op_name)
      return nil if specs.empty?

      meta = capture_entity_attrs(target)
      min_radius = specs.map { |s| s[:radius] }.min
      # 小于 80mm 的孔自动放大 100 倍做布尔/交错，防止 SketchUp 微小面破面
      scale_factor = (min_radius * 2.0) < 80.0.mm ? 100.0 : 1.0

      can_solid_subtract = target.manifold? && target.respond_to?(:subtract)
      used_fallback = false
      result_target = target

      model.start_operation(op_name, true)
      begin
        if can_solid_subtract
          result_target, failed_idx = punch_with_solid_subtract(parent_ents, target, specs, scale_factor)
          if failed_idx
            # 若中途或首次实体布尔失败，对剩余未打的孔自动回退到模型交错
            used_fallback = true
            remaining = specs[failed_idx..-1]
            punch_with_intersect(parent_ents, result_target, remaining, scale_factor) if result_target && result_target.valid?
          end
          copy_entity_attrs(meta, result_target) if result_target && result_target.valid?
        else
          used_fallback = true
          punch_with_intersect(parent_ents, result_target, specs, scale_factor)
        end

        model.selection.clear
        model.selection.add(result_target) if result_target && result_target.valid?
        model.commit_operation
      rescue StandardError => e
        model.abort_operation
        UI.messagebox("打洞失败：#{e.message}")
        return nil
      end

      if used_fallback
        Sketchup.status_text = '已使用【模型交错】模式开洞（提示：原模型非闭合实体，若需带壁厚的实体打洞请先封口成实体群组）。'
      else
        Sketchup.status_text = "打洞完成！共打孔 #{specs.length} 个（实体布尔减法）。"
      end

      result_target
    end

    def punch_with_solid_subtract(parent_ents, target, specs, scale_factor)
      current = target
      t_up    = Geom::Transformation.scaling(ORIGIN, scale_factor)
      t_down  = Geom::Transformation.scaling(ORIGIN, 1.0 / scale_factor)

      parent_ents.transform_entities(t_up, [current]) if scale_factor != 1.0

      specs.each_with_index do |spec, idx|
        p_s   = scale_factor != 1.0 ? spec[:p_start].transform(t_up) : spec[:p_start]
        rad_s = spec[:radius] * scale_factor
        len_s = spec[:length] * scale_factor

        cutter = create_cutter_group(
          parent_ents, p_s, spec[:axis], rad_s, len_s, spec[:segments], spec[:shape]
        )

        unless cutter.manifold? && cutter.respond_to?(:subtract)
          cutter.erase! if cutter.valid?
          parent_ents.transform_entities(t_down, [current]) if scale_factor != 1.0 && current.valid?
          return [current, idx]
        end

        # 注意 SketchUp Ruby API 规则：cutter.subtract(target) 表示从 target 中减去 cutter！
        next_obj = cutter.subtract(current)
        if next_obj.nil? || !next_obj.valid?
          cutter.erase! if cutter.valid?
          parent_ents.transform_entities(t_down, [current]) if scale_factor != 1.0 && current.valid?
          return [current, idx]
        end
        current = next_obj
      end

      parent_ents.transform_entities(t_down, [current]) if scale_factor != 1.0 && current.valid?
      [current, nil]
    end

    def punch_with_intersect(parent_ents, target, specs, scale_factor)
      def_ents = target.is_a?(Sketchup::Group) ? target.entities : target.definition.entities
      t_up     = Geom::Transformation.scaling(ORIGIN, scale_factor)
      t_down   = Geom::Transformation.scaling(ORIGIN, 1.0 / scale_factor)

      parent_ents.transform_entities(t_up, [target]) if scale_factor != 1.0

      specs.each do |spec|
        p_s   = scale_factor != 1.0 ? spec[:p_start].transform(t_up) : spec[:p_start]
        rad_s = spec[:radius] * scale_factor
        len_s = spec[:length] * scale_factor

        scaled_spec = spec.merge(p_start: p_s, radius: rad_s, length: len_s)
        cutter = create_cutter_group(
          parent_ents, p_s, spec[:axis], rad_s, len_s, spec[:segments], spec[:shape]
        )

        # 将钻头交线刻印到目标模型表面
        def_ents.intersect_with(
          false,
          target.transformation,
          def_ents,
          target.transformation,
          true,
          [cutter]
        )

        # 删除落入钻头内部的洞口面
        tr = target.transformation
        faces_to_erase = []
        def_ents.grep(Sketchup::Face).each do |face|
          next unless face.valid?

          wpt = face_interior_point(face).transform(tr)
          faces_to_erase << face if point_inside_cutter?(wpt, scaled_spec)
        end
        def_ents.erase_entities(faces_to_erase) unless faces_to_erase.empty?

        cutter.erase! if cutter.valid?
      end

      parent_ents.transform_entities(t_down, [target]) if scale_factor != 1.0 && target.valid?
      target
    end

    # ------------------------------------------------------------
    # 获取并校验目标群组/组件（若为散面可自动引导打组）
    # ------------------------------------------------------------
    def resolve_target(model)
      active_ents = model.active_entities
      sel = model.selection

      containers = sel.select do |e|
        (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) &&
          e.parent == active_ents.parent
      end

      if containers.length == 1
        return containers.first
      elsif containers.length > 1
        UI.messagebox('请只选中 1 个需要打洞的圆柱群组或组件。')
        return nil
      end

      # 若选中了散面/边线
      loose_sel = sel.select do |e|
        (e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Edge)) &&
          e.parent == active_ents.parent
      end
      unless loose_sel.empty?
        ans = UI.messagebox(
          '你选中的是未打组的散面/边线，是否先自动打包为群组再打洞？',
          MB_YESNO
        )
        return nil unless ans == IDYES

        model.start_operation('自动创建群组', true)
        grp = active_ents.add_group(loose_sel)
        sel.clear
        sel.add(grp)
        model.commit_operation
        return grp
      end

      # 若当前什么都没选中，尝试自动识别场景里的唯一对象
      if sel.empty?
        all_containers = active_ents.select do |e|
          e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        end
        all_loose = active_ents.select do |e|
          e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Edge)
        end

        if all_containers.length == 1 && all_loose.empty?
          sel.add(all_containers.first)
          return all_containers.first
        elsif all_containers.empty? && !all_loose.empty?
          ans = UI.messagebox(
            '检测到模型尚未创建群组，是否自动将当前全部几何体打组并继续打洞？',
            MB_YESNO
          )
          return nil unless ans == IDYES

          model.start_operation('自动创建群组', true)
          grp = active_ents.add_group(all_loose)
          sel.clear
          sel.add(grp)
          model.commit_operation
          return grp
        end
      end

      UI.messagebox('请先单击选中要打洞的圆柱（建议先右键创建群组）。')
      nil
    end

    # ------------------------------------------------------------
    # 功能 1：圆柱侧面一圈/批量打洞
    # ------------------------------------------------------------
    def run_side_holes
      model = Sketchup.active_model
      target = resolve_target(model)
      return unless target

      bounds  = target.bounds
      diam_mm = [bounds.width, bounds.depth].max.to_mm
      ht_mm   = bounds.height.to_mm
      radius_est = [bounds.width, bounds.depth].max / 2.0

      # 智能估算合理默认值
      def_hole_d  = [[(diam_mm * 0.16).round(1), 1.0].max, 500.0].min
      def_height  = [(ht_mm * 0.15).round(1), 1.0].max
      def_depth   = [(diam_mm * 0.25).round(1), 1.0].max

      defaults = @last_side_opts || [
        def_hole_d,
        4,
        def_height,
        '径向向心打穿(推荐)',
        def_depth,
        0.0,
        36,
        '圆孔'
      ]

      prompts = [
        '孔径 / 边长 (mm)',
        '打洞数量 (一圈均匀分布)',
        '孔中心离底部高度 (mm)',
        '打洞深度方式',
        '指定孔深 (mm，仅盲孔生效)',
        '起始角度 (°)',
        '圆孔分段数 (越大越光滑)',
        '孔的形状'
      ]
      lists = [
        '',
        '',
        '',
        '径向向心打穿(推荐)|整根前后贯穿|外侧向内定深盲孔',
        '',
        '',
        '',
        '圆孔|方孔'
      ]
      title = format('圆柱侧面打洞（当前外径约 %.1fmm，高约 %.1fmm）', diam_mm, ht_mm)

      res = UI.inputbox(prompts, defaults, lists, title)
      return unless res

      hole_d_mm  = res[0].to_f
      count      = res[1].to_i
      z_off_mm   = res[2].to_f
      depth_mode = res[3].to_s
      depth_mm   = res[4].to_f
      start_deg  = res[5].to_f
      segments   = [[res[6].to_i, 8].max, 128].min
      shape      = res[7].to_s

      if hole_d_mm <= 0.0 || count <= 0
        UI.messagebox('孔径和打洞数量必须大于 0。')
        return
      end
      if depth_mode == '外侧向内定深盲孔' && depth_mm <= 0.0
        UI.messagebox('定深盲孔的深度必须大于 0。')
        return
      end

      @last_side_opts = res

      cx = bounds.center.x
      cy = bounds.center.y
      cz = bounds.min.z + z_off_mm.mm
      hole_r = (hole_d_mm / 2.0).mm
      margin = [radius_est * 0.25, 10.0.mm].max

      specs = []
      count.times do |i|
        deg = start_deg + i * (360.0 / count)
        rad = deg * Math::PI / 180.0
        out_dir = Geom::Vector3d.new(Math.cos(rad), Math.sin(rad), 0.0)
        center_pt = Geom::Point3d.new(cx, cy, cz)

        case depth_mode
        when '整根前后贯穿'
          p_start = center_pt.offset(out_dir, -(radius_est + margin))
          length  = (radius_est + margin) * 2.0
          axis    = out_dir
        when '外侧向内定深盲孔'
          in_dir  = out_dir.reverse
          p_start = center_pt.offset(out_dir, radius_est + margin)
          length  = depth_mm.mm + margin
          axis    = in_dir
        else # '径向向心打穿(推荐)'
          # 从中心略微越过中心点向外延伸出外壁，空心管/实心柱皆可精准得到 N 个孔口
          overlap = [hole_r * 0.5, 2.0.mm].min
          p_start = center_pt.offset(out_dir, -overlap)
          length  = radius_est + margin + overlap
          axis    = out_dir
        end

        specs << {
          p_start: p_start,
          axis: axis,
          radius: hole_r,
          length: length,
          segments: segments,
          shape: shape
        }
      end

      execute_punch(model, model.active_entities, target, specs, '圆柱侧面批量打洞')
    end

    # ------------------------------------------------------------
    # 功能 2：圆柱底面 / 顶面垂直打洞
    # ------------------------------------------------------------
    def run_end_holes
      model = Sketchup.active_model
      target = resolve_target(model)
      return unless target

      bounds  = target.bounds
      diam_mm = [bounds.width, bounds.depth].max.to_mm
      ht_mm   = bounds.height.to_mm
      radius_est = [bounds.width, bounds.depth].max / 2.0

      def_hole_d = [[(diam_mm * 0.16).round(1), 1.0].max, 500.0].min
      def_pcd_r  = (diam_mm * 0.25).round(1)
      def_depth  = [(ht_mm * 0.2).round(1), 1.0].max

      defaults = @last_end_opts || [
        '底面向上打洞',
        def_hole_d,
        4,
        def_pcd_r,
        '穿透整个模型',
        def_depth,
        0.0,
        36,
        '圆孔'
      ]

      prompts = [
        '打洞端面',
        '孔径 / 边长 (mm)',
        '打洞数量 (1个可打中心)',
        '分布圆半径 (mm，0=正中心)',
        '打洞深度方式',
        '指定孔深 (mm，仅盲孔生效)',
        '起始角度 (°)',
        '圆孔分段数',
        '孔的形状'
      ]
      lists = [
        '底面向上打洞|顶面向下打洞',
        '',
        '',
        '',
        '穿透整个模型|指定孔深(盲孔)',
        '',
        '',
        '',
        '圆孔|方孔'
      ]
      title = format('圆柱底/顶面打洞（外径约 %.1fmm，高约 %.1fmm）', diam_mm, ht_mm)

      res = UI.inputbox(prompts, defaults, lists, title)
      return unless res

      end_side   = res[0].to_s
      hole_d_mm  = res[1].to_f
      count      = res[2].to_i
      pcd_r_mm   = res[3].to_f
      depth_mode = res[4].to_s
      depth_mm   = res[5].to_f
      start_deg  = res[6].to_f
      segments   = [[res[7].to_i, 8].max, 128].min
      shape      = res[8].to_s

      if hole_d_mm <= 0.0 || count <= 0
        UI.messagebox('孔径和打洞数量必须大于 0。')
        return
      end
      if depth_mode == '指定孔深(盲孔)' && depth_mm <= 0.0
        UI.messagebox('盲孔深度必须大于 0。')
        return
      end

      @last_end_opts = res

      cx     = bounds.center.x
      cy     = bounds.center.y
      z_min  = bounds.min.z
      z_max  = bounds.max.z
      hole_r = (hole_d_mm / 2.0).mm
      pcd_r  = pcd_r_mm.mm
      margin = [bounds.height * 0.1, 10.0.mm].max

      # 若数量=1且分布圆半径<=0，直接打在正中心
      actual_count = (pcd_r <= 1.0e-5) ? 1 : count

      specs = []
      actual_count.times do |i|
        deg = start_deg + i * (360.0 / actual_count)
        rad = deg * Math::PI / 180.0
        hx  = cx + pcd_r * Math.cos(rad)
        hy  = cy + pcd_r * Math.sin(rad)

        if end_side == '顶面向下打洞'
          axis    = Z_AXIS.reverse
          p_start = Geom::Point3d.new(hx, hy, z_max + margin)
          length  = (depth_mode == '穿透整个模型') ? (bounds.height + margin * 2.0) : (depth_mm.mm + margin)
        else
          axis    = Z_AXIS
          p_start = Geom::Point3d.new(hx, hy, z_min - margin)
          length  = (depth_mode == '穿透整个模型') ? (bounds.height + margin * 2.0) : (depth_mm.mm + margin)
        end

        specs << {
          p_start: p_start,
          axis: axis,
          radius: hole_r,
          length: length,
          segments: segments,
          shape: shape
        }
      end

      execute_punch(model, model.active_entities, target, specs, '圆柱底面/顶面打洞')
    end

    # ------------------------------------------------------------
    # 功能 3：鼠标指哪打哪（交互式点击任意面打洞工具）
    # ------------------------------------------------------------
    def activate_click_tool
      Sketchup.active_model.select_tool(ClickHoleTool.new)
    end
  end

  class ClickHoleTool
    def initialize
      @ip = Sketchup::InputPoint.new
      @hover_pt_world     = nil
      @hover_normal_world = nil
      @hover_target       = nil
    end

    def activate
      update_ui_status
      Sketchup.active_model.active_view.invalidate
    end

    def deactivate(view)
      view.invalidate
    end

    def resume(view)
      update_ui_status
      view.invalidate
    end

    def opts
      CylHolePuncher.last_click_opts
    end

    def update_ui_status
      o = opts
      depth_desc = o[:depth_mode] == '穿透整个模型' ? '贯穿' : "孔深#{o[:depth_mm]}mm"
      Sketchup.status_text = "【点哪打哪】左键点击任意圆柱/实体表面打洞 | 右键改参数 | 数值框直接输孔径(如 20 或 20,50) | 当前：#{o[:shape]} Ø#{o[:diameter_mm]}mm (#{depth_desc})"
      Sketchup.vcb_label = '孔径[,孔深] mm'
      Sketchup.vcb_value = "#{o[:diameter_mm]}"
    end

    def onMouseMove(_flags, x, y, view)
      @ip.pick(view, x, y)
      update_hover_state
      view.invalidate
    end

    def update_hover_state
      @hover_pt_world     = nil
      @hover_normal_world = nil
      @hover_target       = nil

      face = @ip.face
      return unless face && face.valid?

      model       = Sketchup.active_model
      active_path = model.active_path || []
      inst_path   = @ip.instance_path
      return unless inst_path

      path_arr = inst_path.to_a
      return unless path_arr.length > active_path.length

      candidate = path_arr[active_path.length]
      return unless candidate.is_a?(Sketchup::Group) || candidate.is_a?(Sketchup::ComponentInstance)

      @hover_target       = candidate
      @hover_pt_world     = @ip.position
      @hover_normal_world = face.normal.transform(@ip.transformation).normalize
    end

    def onLButtonDown(_flags, x, y, view)
      @ip.pick(view, x, y)
      update_hover_state

      unless @hover_target && @hover_pt_world && @hover_normal_world
        UI.beep
        Sketchup.status_text = '请点击一个【群组或组件】的表面（散面请先右键创建群组）。'
        return
      end

      model  = Sketchup.active_model
      edit_inv = model.edit_transform.inverse
      pt_local = @hover_pt_world.transform(edit_inv)
      n_local  = @hover_normal_world.transform(edit_inv).normalize

      bounds = @hover_target.bounds
      diag   = bounds.diagonal
      to_ctr = bounds.center - pt_local
      # 确保钻头方向始终朝向模型内部（兼容正反面）
      in_dir = (n_local.dot(to_ctr) >= 0) ? n_local : n_local.reverse

      o = opts
      hole_r = (o[:diameter_mm].to_f / 2.0).mm
      margin = [diag * 0.05, 10.0.mm].max

      p_start = pt_local.offset(in_dir, -margin)
      length = if o[:depth_mode] == '穿透整个模型'
                 diag + margin * 2.0
               else
                 o[:depth_mm].to_f.mm + margin
               end

      spec = {
        p_start: p_start,
        axis: in_dir,
        radius: hole_r,
        length: length,
        segments: o[:segments],
        shape: o[:shape]
      }

      CylHolePuncher.execute_punch(model, model.active_entities, @hover_target, [spec], '交互点击打洞')
      @hover_target = nil
      update_ui_status
      view.invalidate
    end

    def onUserText(text, view)
      parts = text.strip.split(/[,，\s]+/).reject(&:empty?)
      return if parts.empty?

      d = parts[0].to_f
      if d > 0.0
        opts[:diameter_mm] = d
        if parts.length >= 2 && parts[1].to_f > 0.0
          opts[:depth_mode] = '指定孔深(盲孔)'
          opts[:depth_mm]   = parts[1].to_f
        end
        update_ui_status
        view.invalidate
      else
        UI.beep
      end
    end

    def getMenu(menu)
      menu.add_item('设置孔径 / 孔深 / 孔形...') { open_settings_dialog }
      menu.add_item('切换为 穿透整个模型') do
        opts[:depth_mode] = '穿透整个模型'
        update_ui_status
      end
      menu.add_item('切换孔形 (圆孔 / 方孔)') do
        opts[:shape] = (opts[:shape] == '圆孔') ? '方孔' : '圆孔'
        update_ui_status
        Sketchup.active_model.active_view.invalidate
      end
    end

    def open_settings_dialog
      o = opts
      prompts = ['孔径 / 边长 (mm)', '打洞深度方式', '指定孔深 (mm)', '圆孔分段数', '孔的形状']
      defaults = [o[:diameter_mm], o[:depth_mode], o[:depth_mm], o[:segments], o[:shape]]
      lists = ['', '穿透整个模型|指定孔深(盲孔)', '', '', '圆孔|方孔']
      res = UI.inputbox(prompts, defaults, lists, '点哪打哪 - 打洞参数设置')
      return unless res

      o[:diameter_mm] = res[0].to_f if res[0].to_f > 0.0
      o[:depth_mode]  = res[1].to_s
      o[:depth_mm]    = res[2].to_f if res[2].to_f > 0.0
      o[:segments]    = [[res[3].to_i, 8].max, 128].min
      o[:shape]       = res[4].to_s
      update_ui_status
      Sketchup.active_model.active_view.invalidate
    end

    def preview_points
      return [] unless @hover_pt_world && @hover_normal_world

      o = opts
      u, v, n = CylHolePuncher.build_orthonormal_frame(@hover_normal_world)
      r = (o[:diameter_mm].to_f / 2.0).mm
      # 稍微浮出表面一点避免与模型 Z-fighting 闪烁
      base = @hover_pt_world.offset(n, 0.2.mm)

      if o[:shape] == '方孔'
        [
          base.offset(u, -r).offset(v, -r),
          base.offset(u,  r).offset(v, -r),
          base.offset(u,  r).offset(v,  r),
          base.offset(u, -r).offset(v,  r)
        ]
      else
        segs = 32
        Array.new(segs) do |i|
          ang = 2.0 * Math::PI * i / segs
          base.offset(u, r * Math.cos(ang)).offset(v, r * Math.sin(ang))
        end
      end
    end

    def getExtents
      bb = Geom::BoundingBox.new
      pts = preview_points
      bb.add(pts) unless pts.empty?
      bb
    end

    def draw(view)
      @ip.draw(view) if @ip.valid? && @ip.display?
      pts = preview_points
      return if pts.empty?

      view.line_width = 2
      view.drawing_color = Sketchup::Color.new(230, 45, 45)
      view.draw(GL_LINE_LOOP, pts)

      # 画中心十字标记
      u, v, n = CylHolePuncher.build_orthonormal_frame(@hover_normal_world)
      r = (opts[:diameter_mm].to_f / 2.0).mm * 0.35
      base = @hover_pt_world.offset(n, 0.2.mm)
      view.draw(GL_LINES, [
        base.offset(u, -r), base.offset(u, r),
        base.offset(v, -r), base.offset(v, r)
      ])
    end
  end

  # ------------------------------------------------------------
  # 注册菜单、右键菜单与工具栏
  # ------------------------------------------------------------
  unless file_loaded?(__FILE__)
    icon_dir = File.join(File.dirname(__FILE__), 'icons')

    cmd_side = UI::Command.new('圆柱侧面批量打洞') { run_side_holes }
    cmd_side.tooltip = '圆柱侧面一圈/批量打洞'
    cmd_side.status_bar_text = '在圆柱侧面指定高度均匀打一个或多个圆孔/方孔'
    cmd_side.small_icon = File.join(icon_dir, 'side_hole.png')
    cmd_side.large_icon = File.join(icon_dir, 'side_hole.png')

    cmd_end = UI::Command.new('圆柱底面/顶面打洞') { run_end_holes }
    cmd_end.tooltip = '圆柱底面或顶面批量打洞'
    cmd_end.status_bar_text = '在圆柱底面或顶面中心/圆周均匀垂直打孔'
    cmd_end.small_icon = File.join(icon_dir, 'bottom_hole.png')
    cmd_end.large_icon = File.join(icon_dir, 'bottom_hole.png')

    cmd_click = UI::Command.new('鼠标点哪打哪') { activate_click_tool }
    cmd_click.tooltip = '交互点击任意面打洞（指哪打哪）'
    cmd_click.status_bar_text = '点击任意实体/圆柱表面直接垂直打洞，数值框可实时改孔径'
    cmd_click.small_icon = File.join(icon_dir, 'click_hole.png')
    cmd_click.large_icon = File.join(icon_dir, 'click_hole.png')

    # 顶部菜单：扩展程序 -> 圆柱一键打洞
    ext_menu = UI.menu('Extensions')
    sub_menu = ext_menu.add_submenu('圆柱一键打洞')
    sub_menu.add_item(cmd_side)
    sub_menu.add_item(cmd_end)
    sub_menu.add_separator
    sub_menu.add_item(cmd_click)

    # 右键快捷菜单（选中群组或组件时出现）
    UI.add_context_menu_handler do |context_menu|
      sel = Sketchup.active_model.selection
      if sel.length == 1 && (sel.first.is_a?(Sketchup::Group) || sel.first.is_a?(Sketchup::ComponentInstance))
        cm = context_menu.add_submenu('圆柱一键打洞')
        cm.add_item(cmd_side)
        cm.add_item(cmd_end)
        cm.add_item(cmd_click)
      end
    end

    # 浮动工具栏
    toolbar = UI::Toolbar.new('圆柱一键打洞')
    toolbar.add_item(cmd_side)
    toolbar.add_item(cmd_end)
    toolbar.add_item(cmd_click)
    toolbar.restore

    file_loaded(__FILE__)
  end
end
