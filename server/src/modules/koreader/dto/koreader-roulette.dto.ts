import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  IsArray,
  IsIn,
  IsDefined,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  ArrayMinSize,
  MaxLength,
  ValidateNested,
} from 'class-validator';
import { KoreaderWishlistBookDto, KoreaderHubPageDto } from './koreader-hub.dto';
export class RouletteBookDto extends KoreaderWishlistBookDto {
  @IsOptional() @IsString() @MaxLength(8000) description?: string;
  @IsOptional() @IsArray() @ArrayMaxSize(30) @IsString({ each: true }) @MaxLength(120, { each: true }) genres?: string[];
}
export class RouletteDecisionDto {
  @IsOptional() @Matches(/^[a-f0-9]{32}$/) key?: string;
  @IsUUID() eventId!: string;
  @IsIn(['match', 'pass', 'skip', 'remove']) decision!: 'match' | 'pass' | 'skip' | 'remove';
  @IsDefined() @ValidateNested() @Type(() => RouletteBookDto) book!: RouletteBookDto;
}
export class RouletteUndoDto {
  @IsUUID() eventId!: string;
}
export class RouletteQueryDto extends KoreaderHubPageDto {
  @IsOptional() @IsString() @MaxLength(200) q?: string;
  @IsOptional() @IsString() @MaxLength(120) genre?: string;
  @IsOptional() @IsIn(['recent', 'title', 'author']) sort: 'recent' | 'title' | 'author' = 'recent';
}
export class RouletteTasteDto {
  @IsArray() @ArrayMaxSize(12) @IsString({ each: true }) @MaxLength(120, { each: true }) genres!: string[];
  @IsArray() @ArrayMaxSize(10) @IsString({ each: true }) @MaxLength(200, { each: true }) favorites!: string[];
}
export class RouletteAcquireDto {
  @IsArray() @ArrayMinSize(1) @ArrayMaxSize(20) @Matches(/^[a-f0-9]{32}$/, { each: true }) keys!: string[];
}
export class RouletteResetDto {
  @IsIn(['RESET']) confirmation!: 'RESET';
}
