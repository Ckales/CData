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

// dart format on
