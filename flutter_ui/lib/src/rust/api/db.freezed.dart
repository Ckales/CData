// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'db.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$Editability {

 Object get field0;



@override
bool operator ==(Object other) {
  final _this = this as Editability;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Editability&&const DeepCollectionEquality().equals(other.field0, _this.field0));
}


@override
int get hashCode {
  final _this = this as Editability;
  return Object.hash(runtimeType,const DeepCollectionEquality().hash(_this.field0));
}

@override
String toString() {
  final _this = this as Editability;
  return 'Editability(field0: ${_this.field0})';
}


}

/// @nodoc
class $EditabilityCopyWith<$Res>  {
$EditabilityCopyWith(Editability _, $Res Function(Editability) __);
}


/// Adds pattern-matching-related methods to [Editability].
extension EditabilityPatterns on Editability {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( Editability_Editable value)?  editable,TResult Function( Editability_ReadOnly value)?  readOnly,required TResult orElse(),}){
final _that = this;
switch (_that) {
case Editability_Editable() when editable != null:
return editable(_that);case Editability_ReadOnly() when readOnly != null:
return readOnly(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( Editability_Editable value)  editable,required TResult Function( Editability_ReadOnly value)  readOnly,}){
final _that = this;
switch (_that) {
case Editability_Editable():
return editable(_that);case Editability_ReadOnly():
return readOnly(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( Editability_Editable value)?  editable,TResult? Function( Editability_ReadOnly value)?  readOnly,}){
final _that = this;
switch (_that) {
case Editability_Editable() when editable != null:
return editable(_that);case Editability_ReadOnly() when readOnly != null:
return readOnly(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( EditTarget field0)?  editable,TResult Function( String field0)?  readOnly,required TResult orElse(),}) {final _that = this;
switch (_that) {
case Editability_Editable() when editable != null:
return editable(_that.field0);case Editability_ReadOnly() when readOnly != null:
return readOnly(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( EditTarget field0)  editable,required TResult Function( String field0)  readOnly,}) {final _that = this;
switch (_that) {
case Editability_Editable():
return editable(_that.field0);case Editability_ReadOnly():
return readOnly(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( EditTarget field0)?  editable,TResult? Function( String field0)?  readOnly,}) {final _that = this;
switch (_that) {
case Editability_Editable() when editable != null:
return editable(_that.field0);case Editability_ReadOnly() when readOnly != null:
return readOnly(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class Editability_Editable extends Editability {
  const Editability_Editable(this.field0): super._();
  

@override final  EditTarget field0;

/// Create a copy of Editability
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Editability_EditableCopyWith<Editability_Editable> get copyWith => _$Editability_EditableCopyWithImpl<Editability_Editable>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Editability_Editable&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'Editability.editable(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $Editability_EditableCopyWith<$Res> implements $EditabilityCopyWith<$Res> {
  factory $Editability_EditableCopyWith(Editability_Editable value, $Res Function(Editability_Editable) _then) = _$Editability_EditableCopyWithImpl;
@useResult
$Res call({
 EditTarget field0
});




}
/// @nodoc
class _$Editability_EditableCopyWithImpl<$Res>
    implements $Editability_EditableCopyWith<$Res> {
  _$Editability_EditableCopyWithImpl(this._self, this._then);

  final Editability_Editable _self;
  final $Res Function(Editability_Editable) _then;

/// Create a copy of Editability
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(Editability_Editable(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as EditTarget,
  ));
}


}

/// @nodoc


class Editability_ReadOnly extends Editability {
  const Editability_ReadOnly(this.field0): super._();
  

@override final  String field0;

/// Create a copy of Editability
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Editability_ReadOnlyCopyWith<Editability_ReadOnly> get copyWith => _$Editability_ReadOnlyCopyWithImpl<Editability_ReadOnly>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Editability_ReadOnly&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'Editability.readOnly(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $Editability_ReadOnlyCopyWith<$Res> implements $EditabilityCopyWith<$Res> {
  factory $Editability_ReadOnlyCopyWith(Editability_ReadOnly value, $Res Function(Editability_ReadOnly) _then) = _$Editability_ReadOnlyCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$Editability_ReadOnlyCopyWithImpl<$Res>
    implements $Editability_ReadOnlyCopyWith<$Res> {
  _$Editability_ReadOnlyCopyWithImpl(this._self, this._then);

  final Editability_ReadOnly _self;
  final $Res Function(Editability_ReadOnly) _then;

/// Create a copy of Editability
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(Editability_ReadOnly(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$FilterItem {

 Object get field0;



@override
bool operator ==(Object other) {
  final _this = this as FilterItem;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FilterItem&&const DeepCollectionEquality().equals(other.field0, _this.field0));
}


@override
int get hashCode {
  final _this = this as FilterItem;
  return Object.hash(runtimeType,const DeepCollectionEquality().hash(_this.field0));
}

@override
String toString() {
  final _this = this as FilterItem;
  return 'FilterItem(field0: ${_this.field0})';
}


}

/// @nodoc
class $FilterItemCopyWith<$Res>  {
$FilterItemCopyWith(FilterItem _, $Res Function(FilterItem) __);
}


/// Adds pattern-matching-related methods to [FilterItem].
extension FilterItemPatterns on FilterItem {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( FilterItem_Condition value)?  condition,TResult Function( FilterItem_Group value)?  group,required TResult orElse(),}){
final _that = this;
switch (_that) {
case FilterItem_Condition() when condition != null:
return condition(_that);case FilterItem_Group() when group != null:
return group(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( FilterItem_Condition value)  condition,required TResult Function( FilterItem_Group value)  group,}){
final _that = this;
switch (_that) {
case FilterItem_Condition():
return condition(_that);case FilterItem_Group():
return group(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( FilterItem_Condition value)?  condition,TResult? Function( FilterItem_Group value)?  group,}){
final _that = this;
switch (_that) {
case FilterItem_Condition() when condition != null:
return condition(_that);case FilterItem_Group() when group != null:
return group(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( FilterCondition field0)?  condition,TResult Function( FilterGroup field0)?  group,required TResult orElse(),}) {final _that = this;
switch (_that) {
case FilterItem_Condition() when condition != null:
return condition(_that.field0);case FilterItem_Group() when group != null:
return group(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( FilterCondition field0)  condition,required TResult Function( FilterGroup field0)  group,}) {final _that = this;
switch (_that) {
case FilterItem_Condition():
return condition(_that.field0);case FilterItem_Group():
return group(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( FilterCondition field0)?  condition,TResult? Function( FilterGroup field0)?  group,}) {final _that = this;
switch (_that) {
case FilterItem_Condition() when condition != null:
return condition(_that.field0);case FilterItem_Group() when group != null:
return group(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class FilterItem_Condition extends FilterItem {
  const FilterItem_Condition(this.field0): super._();
  

@override final  FilterCondition field0;

/// Create a copy of FilterItem
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FilterItem_ConditionCopyWith<FilterItem_Condition> get copyWith => _$FilterItem_ConditionCopyWithImpl<FilterItem_Condition>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is FilterItem_Condition&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'FilterItem.condition(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $FilterItem_ConditionCopyWith<$Res> implements $FilterItemCopyWith<$Res> {
  factory $FilterItem_ConditionCopyWith(FilterItem_Condition value, $Res Function(FilterItem_Condition) _then) = _$FilterItem_ConditionCopyWithImpl;
@useResult
$Res call({
 FilterCondition field0
});




}
/// @nodoc
class _$FilterItem_ConditionCopyWithImpl<$Res>
    implements $FilterItem_ConditionCopyWith<$Res> {
  _$FilterItem_ConditionCopyWithImpl(this._self, this._then);

  final FilterItem_Condition _self;
  final $Res Function(FilterItem_Condition) _then;

/// Create a copy of FilterItem
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(FilterItem_Condition(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as FilterCondition,
  ));
}


}

/// @nodoc


class FilterItem_Group extends FilterItem {
  const FilterItem_Group(this.field0): super._();
  

@override final  FilterGroup field0;

/// Create a copy of FilterItem
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FilterItem_GroupCopyWith<FilterItem_Group> get copyWith => _$FilterItem_GroupCopyWithImpl<FilterItem_Group>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is FilterItem_Group&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'FilterItem.group(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $FilterItem_GroupCopyWith<$Res> implements $FilterItemCopyWith<$Res> {
  factory $FilterItem_GroupCopyWith(FilterItem_Group value, $Res Function(FilterItem_Group) _then) = _$FilterItem_GroupCopyWithImpl;
@useResult
$Res call({
 FilterGroup field0
});




}
/// @nodoc
class _$FilterItem_GroupCopyWithImpl<$Res>
    implements $FilterItem_GroupCopyWith<$Res> {
  _$FilterItem_GroupCopyWithImpl(this._self, this._then);

  final FilterItem_Group _self;
  final $Res Function(FilterItem_Group) _then;

/// Create a copy of FilterItem
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(FilterItem_Group(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as FilterGroup,
  ));
}


}

// dart format on
