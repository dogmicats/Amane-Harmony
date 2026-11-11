/*
 * 自动生成：public 通道的 MergeBar 空桩（由 _publish/.local/build_release.py 产出）。
 *
 * 分类列表的多选操作条在公版恒为关闭（`BuildConfig.ENABLE_FACET_MULTISELECT = false`），
 * 列表页不会进入选中态，所以这里渲染一个零尺寸占位即可。
 */
import { FacetItem, FacetPick } from '../facets/FacetTypes';

@Component
export struct MergeBar {
  kind: string = 'tag';
  items: FacetItem[] = [];
  picked: FacetPick[] = [];
  onRemove: (id: number) => void = () => {};
  onCancel: () => void = () => {};
  onMerged: () => void = () => {};

  build() {
    Column() {}
      .width(0)
      .height(0)
  }
}
