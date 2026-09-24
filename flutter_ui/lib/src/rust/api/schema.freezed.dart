// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'schema.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$DefaultValue {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is DefaultValue);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'DefaultValue()';
}


}

/// @nodoc
class $DefaultValueCopyWith<$Res>  {
$DefaultValueCopyWith(DefaultValue _, $Res Function(DefaultValue) __);
}


/// Adds pattern-matching-related methods to [DefaultValue].
extension DefaultValuePatterns on DefaultValue {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( DefaultValue_NoDefault value)?  noDefault,TResult Function( DefaultValue_Null value)?  null_,TResult Function( DefaultValue_Literal value)?  literal,TResult Function( DefaultValue_Expression value)?  expression,required TResult orElse(),}){
final _that = this;
switch (_that) {
case DefaultValue_NoDefault() when noDefault != null:
return noDefault(_that);case DefaultValue_Null() when null_ != null:
return null_(_that);case DefaultValue_Literal() when literal != null:
return literal(_that);case DefaultValue_Expression() when expression != null:
return expression(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( DefaultValue_NoDefault value)  noDefault,required TResult Function( DefaultValue_Null value)  null_,required TResult Function( DefaultValue_Literal value)  literal,required TResult Function( DefaultValue_Expression value)  expression,}){
final _that = this;
switch (_that) {
case DefaultValue_NoDefault():
return noDefault(_that);case DefaultValue_Null():
return null_(_that);case DefaultValue_Literal():
return literal(_that);case DefaultValue_Expression():
return expression(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( DefaultValue_NoDefault value)?  noDefault,TResult? Function( DefaultValue_Null value)?  null_,TResult? Function( DefaultValue_Literal value)?  literal,TResult? Function( DefaultValue_Expression value)?  expression,}){
final _that = this;
switch (_that) {
case DefaultValue_NoDefault() when noDefault != null:
return noDefault(_that);case DefaultValue_Null() when null_ != null:
return null_(_that);case DefaultValue_Literal() when literal != null:
return literal(_that);case DefaultValue_Expression() when expression != null:
return expression(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  noDefault,TResult Function()?  null_,TResult Function( String field0)?  literal,TResult Function( String field0)?  expression,required TResult orElse(),}) {final _that = this;
switch (_that) {
case DefaultValue_NoDefault() when noDefault != null:
return noDefault();case DefaultValue_Null() when null_ != null:
return null_();case DefaultValue_Literal() when literal != null:
return literal(_that.field0);case DefaultValue_Expression() when expression != null:
return expression(_that.field0);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  noDefault,required TResult Function()  null_,required TResult Function( String field0)  literal,required TResult Function( String field0)  expression,}) {final _that = this;
switch (_that) {
case DefaultValue_NoDefault():
return noDefault();case DefaultValue_Null():
return null_();case DefaultValue_Literal():
return literal(_that.field0);case DefaultValue_Expression():
return expression(_that.field0);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  noDefault,TResult? Function()?  null_,TResult? Function( String field0)?  literal,TResult? Function( String field0)?  expression,}) {final _that = this;
switch (_that) {
case DefaultValue_NoDefault() when noDefault != null:
return noDefault();case DefaultValue_Null() when null_ != null:
return null_();case DefaultValue_Literal() when literal != null:
return literal(_that.field0);case DefaultValue_Expression() when expression != null:
return expression(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class DefaultValue_NoDefault extends DefaultValue {
  const DefaultValue_NoDefault(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is DefaultValue_NoDefault);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'DefaultValue.noDefault()';
}


}




/// @nodoc


class DefaultValue_Null extends DefaultValue {
  const DefaultValue_Null(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is DefaultValue_Null);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'DefaultValue.null_()';
}


}




/// @nodoc


class DefaultValue_Literal extends DefaultValue {
  const DefaultValue_Literal(this.field0): super._();
  

 final  String field0;

/// Create a copy of DefaultValue
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DefaultValue_LiteralCopyWith<DefaultValue_Literal> get copyWith => _$DefaultValue_LiteralCopyWithImpl<DefaultValue_Literal>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is DefaultValue_Literal&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'DefaultValue.literal(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $DefaultValue_LiteralCopyWith<$Res> implements $DefaultValueCopyWith<$Res> {
  factory $DefaultValue_LiteralCopyWith(DefaultValue_Literal value, $Res Function(DefaultValue_Literal) _then) = _$DefaultValue_LiteralCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$DefaultValue_LiteralCopyWithImpl<$Res>
    implements $DefaultValue_LiteralCopyWith<$Res> {
  _$DefaultValue_LiteralCopyWithImpl(this._self, this._then);

  final DefaultValue_Literal _self;
  final $Res Function(DefaultValue_Literal) _then;

/// Create a copy of DefaultValue
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(DefaultValue_Literal(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class DefaultValue_Expression extends DefaultValue {
  const DefaultValue_Expression(this.field0): super._();
  

 final  String field0;

/// Create a copy of DefaultValue
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DefaultValue_ExpressionCopyWith<DefaultValue_Expression> get copyWith => _$DefaultValue_ExpressionCopyWithImpl<DefaultValue_Expression>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is DefaultValue_Expression&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'DefaultValue.expression(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $DefaultValue_ExpressionCopyWith<$Res> implements $DefaultValueCopyWith<$Res> {
  factory $DefaultValue_ExpressionCopyWith(DefaultValue_Expression value, $Res Function(DefaultValue_Expression) _then) = _$DefaultValue_ExpressionCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$DefaultValue_ExpressionCopyWithImpl<$Res>
    implements $DefaultValue_ExpressionCopyWith<$Res> {
  _$DefaultValue_ExpressionCopyWithImpl(this._self, this._then);

  final DefaultValue_Expression _self;
  final $Res Function(DefaultValue_Expression) _then;

/// Create a copy of DefaultValue
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(DefaultValue_Expression(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
